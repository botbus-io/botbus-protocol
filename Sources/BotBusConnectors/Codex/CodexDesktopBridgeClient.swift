import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import BotBusConnectorKit

/// A virtual Codex process for the existing CodexAppServer parser. Its initialize exchange is
/// answered from the desktop's completed handshake; all subsequent RPC uses the desktop owner.
public struct CodexBridgeProcessLauncher: CodexProcessLauncher {
    public let descriptor: CodexBridgeDescriptor

    public init(descriptor: CodexBridgeDescriptor) { self.descriptor = descriptor }

    public func launch() throws -> any CodexProcessHandle {
        CodexBridgeProcessHandle(descriptor: descriptor)
    }
}

private final class CodexBridgeProcessHandle: CodexProcessHandle, @unchecked Sendable {
    private let state: CodexBridgeRemoteState
    private var iterator: AsyncStream<Data>.Iterator

    init(descriptor: CodexBridgeDescriptor) {
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation = $0 }
        state = CodexBridgeRemoteState(descriptor: descriptor, continuation: continuation)
        iterator = stream.makeAsyncIterator()
    }

    func readStdout() async throws -> Data? { await iterator.next() }

    func writeStdin(_ data: Data) async throws {
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let message = try JSONDecoder().decode(JSONValue.self, from: Data(line))
            try await state.send(message)
        }
    }

    func terminate() { Task { await state.close() } }
    func waitForExit() async -> CodexProcessExit { await state.waitForExit() }
}

private actor CodexBridgeRemoteState {
    private struct Handshake {
        let session: String
        let initialize: JSONValue
    }

    private let descriptor: CodexBridgeDescriptor
    private let continuation: AsyncStream<Data>.Continuation
    private let urlSession: URLSession
    private var connecting: Task<Handshake, Error>?
    private var handshake: Handshake?
    private var polling: Task<Void, Never>?
    private var closed = false
    private let exitBox = OneShotContinuation<CodexProcessExit>()

    init(descriptor: CodexBridgeDescriptor, continuation: AsyncStream<Data>.Continuation) {
        self.descriptor = descriptor
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 28
        config.timeoutIntervalForResource = 30
        urlSession = URLSession(configuration: config)
    }

    func send(_ message: JSONValue) async throws {
        guard !closed else { throw CodexBridgeError.closed }
        let handshake = try await connect()
        if message["method"]?.stringValue == "initialize" {
            guard let id = message["id"] else { throw CodexBridgeError.invalidMessage }
            emit(["id": id, "result": handshake.initialize])
            return
        }
        if message["method"]?.stringValue == "initialized" {
            if polling == nil { polling = Task { [weak self] in await self?.pollLoop() } }
            return
        }
        let payload: JSONValue = ["session": .string(handshake.session), "message": message]
        _ = try await post("/send", body: payload)
    }

    private func connect() async throws -> Handshake {
        if let handshake { return handshake }
        if connecting == nil {
            connecting = Task { [self] in
                let response = try await post("/connect", body: [:])
                guard let session = response["session"]?.stringValue,
                      let initialized = response["initialize"] else { throw CodexBridgeError.invalidMessage }
                return Handshake(session: session, initialize: initialized)
            }
        }
        guard let connecting else { throw CodexBridgeError.closed }
        let value = try await connecting.value
        handshake = value
        return value
    }

    private func pollLoop() async {
        do {
            let session = try await connect().session
            while !Task.isCancelled, !closed {
                let response = try await post("/poll", body: ["session": .string(session)])
                guard let messages = response.arrayValue else { throw CodexBridgeError.invalidMessage }
                for message in messages { emit(message) }
            }
        } catch {
            close(status: -1)
        }
    }

    private func post(_ route: String, body: JSONValue) async throws -> JSONValue {
        guard !closed else { throw CodexBridgeError.closed }
        guard let url = URL(string: "http://127.0.0.1:\(descriptor.port)\(route)") else {
            throw CodexBridgeError.invalidMessage
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(descriptor.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CodexBridgeError.rejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func emit(_ message: JSONValue) {
        guard !closed, var line = try? JSONEncoder().encode(message) else { return }
        line.append(0x0A)
        continuation.yield(line)
    }

    func close() { close(status: 0) }

    private func close(status: Int32) {
        guard !closed else { return }
        closed = true
        polling?.cancel()
        connecting?.cancel()
        urlSession.invalidateAndCancel()
        continuation.finish()
        exitBox.resume(returning: CodexProcessExit(status: status, reason: nil))
    }

    func waitForExit() async -> CodexProcessExit {
        (try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CodexProcessExit, Error>) in
            exitBox.install(continuation)
        }) ?? CodexProcessExit(status: -1, reason: nil)
    }
}

private enum CodexBridgeError: Error {
    case closed, invalidMessage, rejected(Int)
}
