import Foundation
import BotBusConnectorKit
import os

/// 生产用的启动器：真的 fork 一个 `codex app-server` 出来。
///
/// 二进制位置由 `CodexPaths.detectCodexBinary()` 按 ChatGPT / Codex app 的新旧包结构探测。
/// **测试一律不用它**——全套测试走 `CodexProcessHandle` 的假实现，不起进程、不碰 `~/.codex`。
public struct CodexSubprocessLauncher: CodexProcessLauncher {
    public var executablePath: String
    public var arguments: [String]
    /// nil = 继承当前进程的环境（codex 要靠它找 `CODEX_HOME` 与登录态）。
    public var environment: [String: String]?
    public var currentDirectory: URL?
    /// Desktop helper uses the desktop's stderr directly; ordinary Agent mode keeps a tail.
    public var forwardStderr = false

    public init(executablePath: String,
                arguments: [String] = ["app-server"],
                environment: [String: String]? = nil,
                currentDirectory: URL? = nil) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    /// 按 `CodexPaths` 的优先级找一个能用的 codex；一个都没有时返回 nil。
    public static func detected(fileManager: FileManager = .default) -> CodexSubprocessLauncher? {
        guard let path = CodexPaths.detectCodexBinary(fileManager: fileManager) else { return nil }
        return CodexSubprocessLauncher(executablePath: path)
    }

    public func launch() throws -> any CodexProcessHandle {
        try CodexSubprocess(executablePath: executablePath, arguments: arguments,
                            environment: environment, currentDirectory: currentDirectory,
                            forwardStderr: forwardStderr)
    }
}

/// 一个真实的 `codex app-server` 子进程：stdout 走 `AsyncStream`，stdin 走串行队列（整行原子写），
/// stderr 只留最后一小段用于界面提示——**不进日志**，那里面可能有用户的内容。
///
/// `@unchecked Sendable`：内部状态全部由 `lock` 或串行队列保护；`readStdout()` 按协议约定
/// 只被单个读循环串行调用。
final class CodexSubprocess: CodexProcessHandle, @unchecked Sendable {
    /// stderr 只留这么多字节（取末尾）。
    private static let stderrTailLimit = 4096
    private static let exitReasonLimit = 200
    private static let log = Logger(subsystem: "io.botbus.agent", category: "codexsubprocess")

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "io.botbus.agent.codex.stdin")
    private let lock = NSLock()
    private var stderrTail = Data()
    private let exitBox = OneShotContinuation<CodexProcessExit>()
    private let stdoutContinuation: AsyncStream<Data>.Continuation
    /// 只由读循环串行访问（见 `CodexProcessHandle` 的约定）。
    private var stdoutIterator: AsyncStream<Data>.Iterator

    init(executablePath: String, arguments: [String], environment: [String: String]?,
         currentDirectory: URL?, forwardStderr: Bool) throws {
        var captured: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { captured = $0 }
        let outContinuation = captured!
        stdoutContinuation = outContinuation
        stdoutIterator = stream.makeAsyncIterator()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = forwardStderr ? FileHandle.standardError : stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outContinuation.finish()
            } else {
                outContinuation.yield(data)
            }
        }
        if !forwardStderr {
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    self?.appendStderr(data)
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.stdoutContinuation.finish()
            self.exitBox.resume(returning: CodexProcessExit(status: finished.terminationStatus,
                                                            reason: self.takeStderrTail()))
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            outContinuation.finish()
            process.terminationHandler = nil
            exitBox.resume(returning: CodexProcessExit(status: -1, reason: "无法启动 \(executablePath)"))
            throw CodexAppServerError(.launchFailed, "无法启动 \(executablePath)：\(String(describing: error))")
        }
        Self.log.info("codex app-server pid=\(self.process.processIdentifier, privacy: .public)")
    }

    func readStdout() async throws -> Data? {
        await stdoutIterator.next()
    }

    func writeStdin(_ data: Data) async throws {
        // 整行一次写完：两条并发请求交错成半行的话，对端会直接解析失败。
        let box = OneShotContinuation<Void>()
        let handle = stdinPipe.fileHandleForWriting
        writeQueue.async {
            do {
                try handle.write(contentsOf: data)
                box.resume(returning: ())
            } catch {
                box.resume(throwing: error)
            }
        }
        try await withCheckedThrowingContinuation { box.install($0) }
    }

    func terminate() {
        guard process.isRunning else { return }
        try? stdinPipe.fileHandleForWriting.close()
        process.terminate()
    }

    func waitForExit() async -> CodexProcessExit {
        let exit = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CodexProcessExit, Error>) in
            exitBox.install(continuation)
        }
        return exit ?? CodexProcessExit(status: -1, reason: nil)
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        stderrTail.append(data)
        if stderrTail.count > Self.stderrTailLimit {
            stderrTail = Data(stderrTail.suffix(Self.stderrTailLimit))
        }
        lock.unlock()
    }

    /// 给界面看的一句话。**只在这里出现，不写进日志**。
    private func takeStderrTail() -> String? {
        lock.lock()
        let data = stderrTail
        stderrTail = Data()
        lock.unlock()
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return String(text.prefix(Self.exitReasonLimit))
    }
}
