import Foundation
import BotBusConnectorKit

/// Published after the upstream's successful initialize response is forwarded to the desktop.
/// The containing directory is 0700, this file is 0600, and the token is never sent to Relay.
public struct CodexBridgeDescriptor: Codable, Sendable, Equatable {
    public let port: Int
    public let token: String
    public let pid: Int32
    public let parentPID: Int32
    public let instance: String

    public static var defaultDirectory: URL {
        LocalHookServer.defaultSupportDirectory.appendingPathComponent("codex-desktop-bridge", isDirectory: true)
    }

    public static func read(directory: URL = defaultDirectory) -> Self? {
        let file = directory.appendingPathComponent("connection.json")
        guard let directoryAttributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
              let directoryMode = directoryAttributes[.posixPermissions] as? NSNumber,
              directoryMode.intValue & 0o077 == 0,
              let fileAttributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let fileMode = fileAttributes[.posixPermissions] as? NSNumber,
              fileMode.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: file),
              let descriptor = try? JSONDecoder().decode(Self.self, from: data),
              (1...65535).contains(descriptor.port), descriptor.token.count >= 32 else { return nil }
        return descriptor
    }
}

/// Executed as CODEX_CLI_PATH by the ChatGPT desktop. Its upstream process survives Agent
/// disconnections and holds the desktop thread writer locks for the desktop's lifetime.
public actor CodexDesktopBridgeHost {
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let directory: URL
    private let instance = UUID().uuidString
    private let token = UUID().uuidString + UUID().uuidString
    private let output = BridgeDesktopOutput()
    private var router = CodexBridgeRouter()
    private var process: (any CodexProcessHandle)?
    private var server: LocalHookServer?
    private var port: UInt16?
    private var published = false
    private var agentQueue: [JSONValue] = []
    private var agentQueueBytes = 0
    private var pollHold: LocalHookServer.Hold?

    public init(executable: String, arguments: [String], environment: [String: String],
                directory: URL = CodexBridgeDescriptor.defaultDirectory) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }

    public func run() async throws -> Int32 {
        try preparePrivateDirectory()
        var upstreamEnvironment = environment
        upstreamEnvironment.removeValue(forKey: "CODEX_CLI_PATH")
        upstreamEnvironment.removeValue(forKey: "BOTBUS_CODEX_REAL_CLI")
        upstreamEnvironment.removeValue(forKey: "BOTBUS_CODEX_BRIDGE_DIRECTORY")
        var launcher = CodexSubprocessLauncher(executablePath: executable, arguments: arguments,
                                               environment: upstreamEnvironment)
        launcher.forwardStderr = true
        let upstream = try launcher.launch()
        process = upstream
        let endpoint = LocalHookServer(supportDirectory: directory, portFileName: nil,
                                       maxBodyBytes: CodexAppServer.maxLineBytes,
                                       handler: { [weak self] request in
                                           await self?.handle(request) ?? .now(.text(status: 503, "bridge closed"))
                                       })
        server = endpoint
        port = try await endpoint.start()
        let desktop = Task.detached { [weak self] in
            await Self.readDesktopInput { [weak self] message in
                await self?.acceptDesktop(message)
            }
            await self?.desktopClosed()
        }
        let upstreamReader = Task { [weak self] in
            await self?.readUpstream(upstream)
        }
        let exit = await upstream.waitForExit()
        desktop.cancel()
        upstreamReader.cancel()
        await endpoint.stop()
        server = nil
        removeOwnDescriptor()
        pollHold?.answer(.text(status: 503, "bridge closed"))
        pollHold = nil
        return exit.status
    }

    private nonisolated static func readDesktopInput(
        _ accept: @escaping @Sendable (JSONValue) async -> Void
    ) async {
        var lines = BridgeLineBuffer()
        while !Task.isCancelled {
            let data = FileHandle.standardInput.availableData
            if data.isEmpty { break }
            for line in lines.append(data) {
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
                await accept(message)
            }
        }
    }

    private func desktopClosed() {
        process?.terminate()
    }

    private func readUpstream(_ upstream: any CodexProcessHandle) async {
        var lines = BridgeLineBuffer()
        while !Task.isCancelled {
            guard let data = try? await upstream.readStdout() else { break }
            for line in lines.append(data) {
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
                await acceptUpstream(message)
            }
        }
    }

    private func acceptDesktop(_ message: JSONValue) async {
        let deliveries = router.desktop(message)
        do { try await deliver(deliveries) }
        catch { process?.terminate(); return }
        publishIfReady()
    }

    private func acceptUpstream(_ message: JSONValue) async {
        let deliveries = router.upstream(message)
        do { try await deliver(deliveries) }
        catch { process?.terminate(); return }
        publishIfReady()
    }

    private func deliver(_ deliveries: [CodexBridgeRouter.Delivery]) async throws {
        for delivery in deliveries {
            let encoded = try JSONEncoder().encode(delivery.message)
            var line = encoded
            line.append(0x0A)
            switch delivery {
            case .upstream:
                guard let process else { throw CodexBridgeHostError.upstreamUnavailable }
                try await process.writeStdin(line)
            case .desktop:
                await output.write(line)
            case .agent:
                await queueForAgent(delivery.message, bytes: line.count)
            }
        }
    }

    private func queueForAgent(_ message: JSONValue, bytes: Int) async {
        if let pollHold {
            self.pollHold = nil
            if pollHold.answer(Self.json(.array([message]))) { return }
        }
        guard agentQueue.count < 512, agentQueueBytes + bytes <= 32 * 1024 * 1024 else {
            router.detach()
            agentQueue.removeAll()
            agentQueueBytes = 0
            return
        }
        agentQueue.append(message)
        agentQueueBytes += bytes
    }

    private func handle(_ request: LocalHookServer.Request) async -> LocalHookServer.Reply {
        guard request.header("authorization") == "Bearer \(token)" else {
            return .now(.text(status: 401, "unauthorized"))
        }
        switch request.path {
        case "/status":
            return .now(Self.json(["ready": .bool(router.ready), "instance": .string(instance)]))
        case "/connect":
            guard router.ready, let initialized = router.initializeResult else {
                return .now(.text(status: 503, "desktop handshake pending"))
            }
            let session = UUID().uuidString
            let pending = router.attach(session)
            agentQueue = pending
            agentQueueBytes = pending.reduce(0) { $0 + ((try? JSONEncoder().encode($1).count) ?? 0) }
            pollHold?.answer(.text(status: 409, "replaced"))
            pollHold = nil
            return .now(Self.json(["session": .string(session), "initialize": initialized]))
        case "/send":
            guard let payload = try? JSONDecoder().decode(JSONValue.self, from: request.body),
                  let session = payload["session"]?.stringValue,
                  let message = payload["message"] else {
                return .now(.text(status: 400, "invalid message"))
            }
            let deliveries: [CodexBridgeRouter.Delivery]
            do { deliveries = try router.agent(message, session: session) }
            catch {
                return .now(.text(status: 409, "stale or unsupported command"))
            }
            do {
                try await deliver(deliveries)
                return .now(.json("{}"))
            } catch {
                process?.terminate()
                return .now(.text(status: 503, "Codex upstream unavailable"))
            }
        case "/poll":
            guard let payload = try? JSONDecoder().decode(JSONValue.self, from: request.body),
                  payload["session"]?.stringValue == router.agentSession else {
                return .now(.text(status: 409, "stale session"))
            }
            if !agentQueue.isEmpty {
                let batch = agentQueue
                agentQueue.removeAll()
                agentQueueBytes = 0
                return .now(Self.json(.array(batch)))
            }
            // A timed-out or disconnected Hold can remain in this actor after its HTTP
            // response has finished. Settle the old poll before accepting the next one.
            if let pollHold {
                self.pollHold = nil
                _ = pollHold.answer(Self.json(.array([])))
            }
            let hold = LocalHookServer.Hold(timeout: 20, onTimeout: { Self.json(.array([])) })
            pollHold = hold
            return .hold(hold)
        default:
            return .now(.text(status: 404, "unknown route"))
        }
    }

    private func publishIfReady() {
        guard router.ready, !published, let port else { return }
        let descriptor = CodexBridgeDescriptor(port: Int(port), token: token,
                                               pid: getpid(), parentPID: getppid(), instance: instance)
        do {
            let data = try JSONEncoder().encode(descriptor)
            let url = directory.appendingPathComponent("connection.json")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            published = true
        } catch {
            // No descriptor means the Agent never attempts to attach to an unprotected endpoint.
        }
    }

    private func preparePrivateDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else {
            throw CodexBridgeRouter.Failure.forbiddenMethod
        }
    }

    private func removeOwnDescriptor() {
        let url = directory.appendingPathComponent("connection.json")
        if CodexBridgeDescriptor.read(directory: directory)?.instance == instance {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func json(_ value: JSONValue) -> LocalHookServer.Response {
        guard let data = try? JSONEncoder().encode(value) else { return .text(status: 500, "encode failed") }
        return .json(data)
    }
}

private enum CodexBridgeHostError: Error {
    case upstreamUnavailable
}

private actor BridgeDesktopOutput {
    func write(_ data: Data) {
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

/// JSON lines; invalid oversized frames are discarded through their terminating newline.
private struct BridgeLineBuffer {
    private var buffer = Data()
    private var overflowing = false

    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var result: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<index])
            buffer.removeSubrange(...index)
            if !overflowing, line.count <= CodexAppServer.maxLineBytes { result.append(line) }
            overflowing = false
        }
        if buffer.count > CodexAppServer.maxLineBytes {
            buffer.removeAll()
            overflowing = true
        }
        return result
    }
}
