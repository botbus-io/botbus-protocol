import Foundation
#if canImport(os)
import os
#endif
import BotBusProtocol
import BotBusConnectorKit

/// Pi 连接器：会话 JSONL 由 `SessionObserver` + `PiSessionSource` 负责"看见"，本连接器只负责"动手"——
/// `startTask` / `followUp` 各起一个 `pi --mode json` 子进程，一轮跑完就退出。
///
/// **所有权只在自己那一轮里拿着**（spec 的"所有权"一节）：session id 一到手就 `claimLive`，
/// 子进程结束写完最终状态后 `releaseLive`，交还观察者（`TaskStore` 的 30 秒宽限盖住落盘滞后），
/// 再调 `onRunFinished` 催观察者立刻读一轮。和 Claude 那种"一拿就不放"不同：Pi 有观察者，
/// 桌面上的会话归它管，我们不该长期挡着它。
///
/// Pi 没有审批，也没有 MCP：手机任务只注入 `BOTBUS_*` 环境变量与 `--append-system-prompt` 的
/// CLI 版说明文字（`cliOnlyInstructions`），让 agent 在 shell 里调 `botbus`。
///
/// **未在真实 pi 上验证**（spec"未验证 / 发布前必做"）：首行是否确为 header、SIGINT 的行为都按文档推断。
public actor PiConnector: TaskConnector {
    public nonisolated var kind: ConnectorKind { .pi }

    /// 等首行 header（里面才有 session id）的上限。命令回执只表示"已接受"，不该为它等一整轮。
    static let sessionIDTimeout: TimeInterval = 20
    /// 收尾后隔多久再补一次 `releaseLive`，见 `complete(_:releasing:)`。
    static let releaseRetryDelay: TimeInterval = 1

    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "pi")

    /// 一次子进程启动。以启动为单位记账而不是以 session 为单位：id 要等首行才知道，
    /// 而子进程可能在那之前、或在 `start` 还没登记完时就已经结束了。
    private struct Launch {
        var handle: any PiProcessHandle
        var sessionID: String?
        /// `start` / `followUp` 已经写完 running 状态。在此之前到达的结束只记下，由它们收尾——
        /// 否则结束先写 completed、随后的 running 反把它盖掉，任务就永远停在"运行中"。
        var ready = false
        var result: PiJSONStreamReader.Result?
    }

    private let store: TaskStore
    private let paths: @Sendable () -> PiPaths
    private let binary: @Sendable () -> String?
    private let launcher: any PiProcessLauncher
    private let now: @Sendable () -> Date
    private let tools: @Sendable () -> AgentToolsConfiguration?
    private let registry: TaskContextRegistry
    private let onRunFinished: @Sendable () async -> Void

    private var launches: [UUID: Launch] = [:]
    /// 正在跑的那一轮：sessionId → 启动。`interrupt` 与"正在运行不能续聊"都看它。
    private var active: [String: UUID] = [:]
    /// 已经在起子进程、还没拿到 header 的续聊：挡住同一会话的并发续聊。
    private var launching: Set<String> = []
    /// 我们驱动过的任务的最新记录，收尾时在它上面改状态。
    private var records: [String: TaskRecord] = [:]

    /// - Parameters:
    ///   - launcher: 测试注入假的，永远不起真实 `pi`。
    ///   - tools: 每次起子进程时现取；nil 或不可用 = 不注入 agent 工具。
    ///   - registry: 签发与绑定 task token；app 里与本机工具服务器共用同一个实例。
    ///   - onRunFinished: 一轮结束、所有权交还之后调用；app 用它催 `SessionObserver.pollOnce()`。
    public init(store: TaskStore,
                paths: @escaping @Sendable () -> PiPaths = { PiPaths() },
                binary: @escaping @Sendable () -> String? = { PiPaths.detectPiBinary() },
                launcher: any PiProcessLauncher = PiSubprocessLauncher(),
                now: @escaping @Sendable () -> Date = { Date() },
                tools: @escaping @Sendable () -> AgentToolsConfiguration? = { nil },
                registry: TaskContextRegistry = TaskContextRegistry(),
                onRunFinished: @escaping @Sendable () async -> Void = {}) {
        self.store = store
        self.paths = paths
        self.binary = binary
        self.launcher = launcher
        self.now = now
        self.tools = tools
        self.registry = registry
        self.onRunFinished = onRunFinished
    }

    /// 停连接器：终止我们自己起的子进程。先把它们标成 interrupted，随后到达的"进程退出"不会把它们改成 failed。
    public func stop() {
        for (sessionID, _) in active {
            records[sessionID]?.status = .interrupted
        }
        for launch in launches.values { launch.handle.terminate() }
    }

    // MARK: - TaskConnector

    public func start(projectPath: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        // 协议 2.9 的手机发图本期只接了 Codex 与 Claude；明说不支持，别只发文字让用户以为 agent 看过图。
        guard images.isEmpty else { throw ConnectorError("这个 Agent 暂不支持发图") }
        guard Self.isDirectory(projectPath) else { throw ConnectorError("项目目录不存在：\(projectPath)") }
        let injection = await AgentToolsInjection.make(tools(), registry: registry)
        let (launchID, sessionID) = try await launch(
            arguments: Self.arguments(prompt: prompt, sessionFile: nil, injection: injection),
            workingDirectory: projectPath, injection: injection)
        let taskId = self.taskId(for: sessionID)
        let timestamp = ProtocolJSON.timestamp(now())
        let projectName = SessionFormatting.projectName(projectPath)
        let title = SessionFormatting.truncate(PiText.singleLine(prompt), SessionFormatting.titleLimit)
        let record = TaskRecord(id: taskId, agentId: "", source: .pi,
                                title: title.isEmpty ? (projectName.isEmpty ? "Pi 会话" : projectName) : title,
                                projectPath: projectPath, projectName: projectName, status: .running,
                                origin: .watch,
                                // 自己起的这一轮能中断、结束后能续聊。
                                controllable: true,
                                startedAt: timestamp, updatedAt: timestamp)
        if let injection { await registry.bind(injection.token, taskId: taskId) }
        let stillRunning = await markRunning(record, launchID: launchID)
        return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: stillRunning)
    }

    public func followUp(taskId: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        guard images.isEmpty else { throw ConnectorError("这个 Agent 暂不支持发图") }
        let sessionID = try nativeTaskId(taskId, kind: .pi)
        guard active[sessionID] == nil, !launching.contains(sessionID) else {
            throw ConnectorError("这个会话正在运行，等它这一轮结束再续聊")
        }
        // 第一个 await 之前就占位：`active` 要等 header 到了才写，中间最多 20 秒，
        // 手机和手表同时发的两条续聊会各起一个 pi 往同一份 JSONL 里追加。
        launching.insert(sessionID)
        defer { launching.remove(sessionID) }
        if let existing = await store.task(id: self.taskId(for: sessionID)),
           existing.status == .running, existing.origin == .desktop {
            // 电脑上正开着的会话不是我们的进程：再起一个 `--session` 会和它抢着写同一个文件。
            throw ConnectorError("这个会话正在电脑上运行，等它停下再续聊")
        }
        guard let file = PiSessionReader(paths: paths()).sessionFile(for: sessionID) else {
            throw ConnectorError("找不到这个 Pi 会话的记录文件")
        }
        // 没有 `--cwd`：子进程的工作目录就是会话的 cwd，以 header 为准（目录名反解不回路径）。
        guard let header = PiSessionFile.header(atPath: file.path) else {
            throw ConnectorError("这个 Pi 会话的记录文件认不出来")
        }
        guard Self.isDirectory(header.cwd) else { throw ConnectorError("项目目录不存在：\(header.cwd)") }

        // 续聊沿用这条任务之前的 token（agent 若把它记在了别处也照样有效）。
        let injection = await AgentToolsInjection.make(tools(), registry: registry, reusing: self.taskId(for: sessionID))
        // 只传绝对路径：传 id 若命中别的项目，pi 会弹"fork 到当前目录？"的确认，子进程就卡死了。
        let (launchID, resolvedID) = try await launch(
            arguments: Self.arguments(prompt: prompt, sessionFile: file.path, injection: injection),
            workingDirectory: header.cwd, injection: injection)
        let resultingTaskId = self.taskId(for: resolvedID)
        if let injection { await registry.bind(injection.token, taskId: resultingTaskId) }

        let timestamp = ProtocolJSON.timestamp(now())
        let existing = await store.task(id: resultingTaskId)
        var record = existing ?? records[resolvedID] ?? TaskRecord(
            id: resultingTaskId, agentId: "", source: .pi,
            title: SessionFormatting.truncate(PiText.singleLine(prompt), SessionFormatting.titleLimit),
            projectPath: header.cwd, projectName: SessionFormatting.projectName(header.cwd), status: .running,
            origin: .watch, controllable: true,
            startedAt: ProtocolJSON.timestamp(header.timestamp ?? now()), updatedAt: timestamp)
        record.status = .running
        record.pendingRequest = nil
        record.controllable = true
        record.updatedAt = timestamp
        // 产物由 TaskStore 自己合并，这里带着旧值写回去也不会覆盖它；清掉只是不让连接器持有它。
        record.artifacts = nil
        let stillRunning = await markRunning(record, launchID: launchID)
        return ConnectorOutcome(taskId: resultingTaskId, retainsLiveOwnership: stillRunning)
    }

    public func approve(taskId: String, requestId: String,
                        decision: Command.Approve.Decision) async throws -> ConnectorOutcome {
        throw ConnectorError("Pi 没有审批机制，工具调用不需要批准")
    }

    public func interrupt(taskId: String) async throws -> ConnectorOutcome {
        let sessionID = try nativeTaskId(taskId, kind: .pi)
        guard let launchID = active[sessionID], let launch = launches[launchID] else {
            // 桌面上用户自己开的会话不是我们的子进程，发不了信号。
            throw ConnectorError("这个会话是在电脑上启动的，只能在电脑上中断")
        }
        launch.handle.interrupt()
        if var record = records[sessionID] {
            record.status = .interrupted
            record.updatedAt = ProtocolJSON.timestamp(now())
            records[sessionID] = record
            await store.upsert(record)
        }
        // 子进程退出时由收尾交还所有权。
        return ConnectorOutcome(taskId: self.taskId(for: sessionID), retainsLiveOwnership: true)
    }

    // MARK: - 参数

    /// `pi` 的完整参数：`--mode json [--session <绝对路径>] [--append-system-prompt <说明>] <prompt>`。
    ///
    /// prompt 以 `-` 或 `@` 开头时前面垫一个空格：pi 会把 `-x` 当成选项、把 `@路径` 当成要附带的文件，
    /// 手机上随手打的一句话不该被解释成命令行语法。模型看到的只是多一个前导空格。
    static func arguments(prompt: String, sessionFile: String?, injection: AgentToolsInjection?) -> [String] {
        var arguments = ["--mode", "json"]
        if let sessionFile { arguments += ["--session", sessionFile] }
        if let injection { arguments += ["--append-system-prompt", injection.cliOnlyInstructions] }
        arguments.append(prompt.hasPrefix("-") || prompt.hasPrefix("@") ? " " + prompt : prompt)
        return arguments
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - 子进程

    /// 起一个 `pi --mode json …` 并**只等到首行 header 出现就返回**。剩下的输出在后台接着读，
    /// 结束时经 `runFinished` 收尾——一轮可能跑几分钟，不能让命令回执挂在那里。
    private func launch(arguments: [String], workingDirectory: String,
                        injection: AgentToolsInjection?) async throws -> (UUID, String) {
        guard let executable = binary() else { throw ConnectorError("本机没找到 pi 可执行文件") }
        let launchID = UUID()
        let sessionID = OneShotContinuation<String>()
        let reader = PiJSONStreamReader()
        reader.onSessionID = { sessionID.resume(returning: $0) }
        reader.onFinished = { [weak self] result in
            Task { await self?.runFinished(launchID, result) }
        }

        let request = PiLaunchRequest(
            executable: executable, arguments: arguments, workingDirectory: workingDirectory,
            // pi 是 `#!/usr/bin/env node` 脚本：可执行文件所在目录要补到 PATH 最前，GUI 进程才找得到 node。
            environment: AgentBinary.environment(for: executable, adding: injection?.environment ?? [:]))
        let handle: any PiProcessHandle
        do {
            handle = try launcher.launch(request, onOutput: { reader.consume($0) }, onExit: { status in
                // 一行 header 都没吐出来就退了：别让调用方一直等到超时。
                sessionID.resume(throwing: ConnectorError("pi 退出了，没有拿到会话 id（退出码 \(status)）"))
                reader.finish(exitStatus: status)
            })
        } catch {
            throw ConnectorError("起不了 pi：\(error.localizedDescription)")
        }
        // 这里到下一个 await 之间不会有别的 actor 调用插进来，所以 runFinished 一定看得到这条登记。
        launches[launchID] = Launch(handle: handle)

        let id: String
        do {
            id = try await awaitSessionID(sessionID)
        } catch {
            // 超时或提前退出：进程若还活着就别留一个没人认领的孤儿。
            handle.terminate()
            launches.removeValue(forKey: launchID)
            throw error
        }
        launches[launchID]?.sessionID = id
        active[id] = launchID
        return (launchID, id)
    }

    /// 等 session id，带硬超时。两条路径抢的是同一个 `OneShotContinuation`，不会二次 resume。
    private func awaitSessionID(_ box: OneShotContinuation<String>) async throws -> String {
        let timer = Task {
            try? await Task.sleep(for: .seconds(Self.sessionIDTimeout))
            box.resume(throwing: ConnectorError("等 pi 回应超时"))
        }
        defer { timer.cancel() }
        return try await box.value()
    }

    /// 写 running 状态并认领所有权。返回这一轮是否还在跑：已经跑完（结束在登记完成前到达）时
    /// 在这里就地收尾，但**不交还**所有权——分发器拿到 `retainsLiveOwnership: false` 后会自己 claim 再 release，
    /// 我们先 release 的话分发器随后那一手 claim 就再也没人放了。
    private func markRunning(_ record: TaskRecord, launchID: UUID) async -> Bool {
        let sessionID = String(record.id.dropFirst("pi:".count))
        records[sessionID] = record
        await store.claimLive(record.id)
        await store.upsert(record)
        guard launches[launchID] != nil else { return false }
        launches[launchID]?.ready = true
        guard launches[launchID]?.result != nil else { return true }
        await complete(launchID, releasing: false)
        return false
    }

    /// 后台读完一轮（或进程退出）。`start` / `followUp` 还没写完 running 时只记下结果，由它们收尾。
    private func runFinished(_ launchID: UUID, _ result: PiJSONStreamReader.Result) async {
        guard var launch = launches[launchID], launch.result == nil else { return }
        launch.result = result
        launches[launchID] = launch
        guard launch.ready else { return }
        await complete(launchID, releasing: true)
    }

    private func releaseIfIdle(sessionID: String, taskId: String) async {
        guard active[sessionID] == nil else { return }
        await store.releaseLive(taskId)
    }

    /// 写最终状态 → 交还所有权 → 催观察者。
    private func complete(_ launchID: UUID, releasing: Bool) async {
        guard let launch = launches.removeValue(forKey: launchID),
              let result = launch.result, let sessionID = launch.sessionID else { return }
        if active[sessionID] == launchID { active.removeValue(forKey: sessionID) }
        guard var record = records[sessionID] else { return }
        // 已经被 interrupt / stop 标过的不要被"进程退出"改回 completed 或 failed。
        if record.status != .interrupted {
            record.status = result.failed ? .failed : (result.aborted ? .interrupted : .completed)
        }
        if let text = result.lastText, !text.trimmed.isEmpty {
            record.lastMessage = SessionFormatting.truncate(text, SessionFormatting.lastMessageLimit)
        } else if result.failed, let error = result.errorMessage, !error.trimmed.isEmpty {
            // 出错的一轮往往没有正文：把 pi 给的错误原因放上去，手机上至少知道为什么失败。
            record.lastMessage = SessionFormatting.truncate(error, SessionFormatting.lastMessageLimit)
        }
        record.pendingRequest = nil
        record.updatedAt = ProtocolJSON.timestamp(now())
        records[sessionID] = record
        await store.upsert(record)
        // 写状态的空当里可能已经有新一轮续聊起来了：那一轮自己拿着所有权，这里不能替它放掉。
        if releasing, active[sessionID] == nil {
            await store.releaseLive(record.id)
            // 兜底：分发器在 `start` 返回**之后**才 claim 一次。这一轮若恰好在"回执已返回、分发器还没 claim"
            // 的空当里结束，我们这次 release 会先于那次 claim，所有权就永远卡在 live、观察者再也改不动它。
            // 过一会儿再放一次；期间若已有新一轮在跑就不动（它自己拿着所有权）。
            let taskId = record.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.releaseRetryDelay))
                await self?.releaseIfIdle(sessionID: sessionID, taskId: taskId)
            }
        }
        Self.log.info("pi run finished: \(record.status.rawValue, privacy: .public)")
        await onRunFinished()
    }
}

// MARK: - 进程抽象

/// 起一个 `pi` 子进程需要的全部。
public struct PiLaunchRequest: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]

    public init(executable: String, arguments: [String], workingDirectory: String, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

/// 一个跑着的 `pi`。只需要两种信号：中断这一轮、停机时终止。
public protocol PiProcessHandle: AnyObject, Sendable {
    /// SIGINT：pi 把当前轮次标成 `aborted` 然后退出。
    func interrupt()
    func terminate()
}

/// 可替换的启动器：生产用 `PiSubprocessLauncher`，测试注入假的，全套测试不起真实进程。
public protocol PiProcessLauncher: Sendable {
    /// - Parameters:
    ///   - onOutput: stdout 的原始字节块（不保证按行切），任意线程回调。
    ///   - onExit: 进程退出**且** stdout 读完之后调用一次，参数是退出码。
    func launch(_ request: PiLaunchRequest,
                onOutput: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws -> any PiProcessHandle
}

public struct PiSubprocessLauncher: PiProcessLauncher {
    public init() {}

    public func launch(_ request: PiLaunchRequest,
                       onOutput: @escaping @Sendable (Data) -> Void,
                       onExit: @escaping @Sendable (Int32) -> Void) throws -> any PiProcessHandle {
        try PiSubprocess(request, onOutput: onOutput, onExit: onExit)
    }
}

/// 真实的 `pi` 子进程。退出与 stdout 的 EOF 是两条独立的回调，谁先到都有可能；
/// 两样都到了才报 `onExit`，否则最后几行（`message_end` / `agent_settled`）会在收尾之后才到，白读了。
final class PiSubprocess: PiProcessHandle, @unchecked Sendable {
    private let process = Process()
    /// stdout：退出后 EOF 迟迟不来（孙进程攥着）时由 `markExit` 收掉读端。
    private let output = Pipe()
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var reachedEOF = false
    private var reported = false
    private let onExit: @Sendable (Int32) -> Void

    init(_ request: PiLaunchRequest, onOutput: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) throws {
        self.onExit = onExit
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory)
        let output = self.output
        process.standardOutput = output
        // stderr 没人读：给 Pipe 的话写满 64 KB 缓冲 pi 就阻塞了。stdin 同 GUI 进程本来的样子（空）。
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        output.fileHandleForReading.portableReadabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // 不只摘 handler：Linux 上还得关读端，否则每一轮 pi 漏一个描述符。
                handle.finishPortableReading()
                self?.markEOF()
            } else {
                onOutput(chunk)
            }
        }
        // 强引用 self 直到进程退出：连接器收尾后就不再持有这个对象，但进程还得有人等。
        process.terminationHandler = { finished in
            self.markExit(finished.terminationStatus)
            finished.terminationHandler = nil
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.finishPortableReading()
            try? output.fileHandleForWriting.close()
            process.terminationHandler = nil
            throw error
        }
    }

    func interrupt() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGINT)
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    private func markEOF() {
        lock.lock(); reachedEOF = true; lock.unlock()
        reportIfDone()
    }

    private func markExit(_ status: Int32) {
        lock.lock(); exitStatus = status; lock.unlock()
        reportIfDone()
        // 子进程若把 stdout 交给了还活着的孙进程，EOF 可能永远不来；退出后最多再等 2 秒，
        // 之后不再读（读端在 Linux 上一并关掉，孙进程再写只会收到 EPIPE）。
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            self.output.fileHandleForReading.finishPortableReading()
            self.markEOF()
        }
    }

    private func reportIfDone() {
        lock.lock()
        guard !reported, reachedEOF, let status = exitStatus else {
            lock.unlock()
            return
        }
        reported = true
        lock.unlock()
        onExit(status)
    }
}

// MARK: - 输出解析

/// 读 `pi --mode json` 的 stdout：一行一个 JSON 事件。只关心——
/// - 首个 `{"type":"session","id":…}`（就是会话 header）：session id，命令回执等的就是它；
/// - `message_end` 里的 assistant 消息：留最后一段文本与 `stopReason`；
/// - `agent_settled`：这一轮真正结束（`agent_end` 之后还可能有自动重试 / 压缩，所以不认它）。
///
/// 其余事件（增量、工具执行）一律忽略，**全程容错**：多一种没见过的事件不该让整轮白跑。
final class PiJSONStreamReader: @unchecked Sendable {
    struct Result: Sendable, Hashable {
        var sessionID: String?
        var lastText: String?
        /// 退出码非 0，或最后一条 assistant 的 `stopReason` 是 `error`。
        var failed: Bool
        /// 最后一条 assistant 的 `stopReason` 是 `aborted`。
        var aborted: Bool
        var errorMessage: String?
    }

    private let lock = NSLock()
    private var buffer = Data()
    private var sessionID: String?
    private var lastText: String?
    private var lastStopReason: String?
    private var errorMessage: String?
    private var finished = false
    private var sessionIDCallback: (@Sendable (String) -> Void)?
    private var finishedCallback: (@Sendable (Result) -> Void)?

    /// 必须在喂数据之前设好。
    var onSessionID: (@Sendable (String) -> Void)? {
        get { lock.withLock { sessionIDCallback } }
        set { lock.withLock { sessionIDCallback = newValue } }
    }

    var onFinished: (@Sendable (Result) -> Void)? {
        get { lock.withLock { finishedCallback } }
        set { lock.withLock { finishedCallback = newValue } }
    }

    func consume(_ chunk: Data) {
        var lines: [Data] = []
        lock.lock()
        buffer.append(chunk)
        while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Data(buffer[buffer.startIndex..<index]))
            buffer = Data(buffer[buffer.index(after: index)...])
        }
        // 一行都没读完整就先攒着。上限只是防一个坏掉的流把内存吃光。
        if buffer.count > 1 << 22 { buffer.removeAll(keepingCapacity: false) }
        lock.unlock()
        for line in lines { handle(line) }
    }

    /// 幂等：`agent_settled` 与进程退出各会调一次，只有第一次作数。
    /// - Parameter exitStatus: 进程退出码；由 `agent_settled` 触发时为 nil（进程还没退）。
    func finish(exitStatus: Int32?) {
        if exitStatus != nil {
            // 进程退出时缓冲里可能还剩没带换行的最后一行。`agent_settled` 触发时流还没完，不能动缓冲。
            lock.lock()
            let tail = buffer
            buffer.removeAll()
            lock.unlock()
            if !tail.isEmpty { handle(tail) }
        }

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let callback = finishedCallback
        let result = Result(sessionID: sessionID, lastText: lastText,
                            failed: (exitStatus ?? 0) != 0 || lastStopReason == "error",
                            aborted: lastStopReason == "aborted",
                            errorMessage: errorMessage)
        lock.unlock()
        callback?(result)
    }

    private func handle(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        switch object["type"] as? String {
        case "session":
            lock.lock()
            guard sessionID == nil, let id = object["id"] as? String, !id.isEmpty else {
                lock.unlock()
                return
            }
            sessionID = id
            let callback = sessionIDCallback
            lock.unlock()
            callback?(id)
        case "message_end":
            guard let message = (object["message"] as? [String: Any]).flatMap(PiMessage.init(object:)),
                  message.role == .assistant else { return }
            let raw = (object["message"] as? [String: Any])?["errorMessage"] as? String
            lock.withLock {
                lastStopReason = message.stopReason
                if !message.text.trimmed.isEmpty { lastText = message.text }
                if let raw, !raw.isEmpty { errorMessage = raw }
            }
        case "agent_settled":
            finish(exitStatus: nil)
        default:
            break
        }
    }
}
