import Foundation
#if canImport(os)
import os
#endif
import BotBusProtocol
import BotBusConnectorKit

/// Hermes Agent（Nous Research）连接器：`hermes chat -q … --format stream-json` 负责"动手"。
///
/// "看见"不在这里：桌面上的会话由 `SessionObserver` + `HermesStateSource` 轮询 `state.db` 对账。
/// 本连接器只在**自己起的那一轮**里认领实时所有权（`claimLive`），子进程一结束就写最终状态、
/// `releaseLive`（`TaskStore` 的 30 秒交接宽限盖住落盘滞后），再催观察者 `onRunFinished` 马上读一轮。
/// 与 Claude 连接器"一拿就不放"正相反——那边没有观察者，这边有。
///
/// **审批做不了**：`-q` 模式没有审批通道，危险命令按 Hermes 自己的 `approvals.single_query_mode`
/// （默认 `deny`）处理。真正的审批要走 ACP（`hermes acp`），本期不做（spec「Hermes」一节）。
///
/// **手机任务带上 agent 工具**：`-q` 不能临时挂 MCP，所以只注入三个 `BOTBUS_*` 环境变量，
/// 说明文字用只讲 CLI 的那一版，经 `HERMES_EPHEMERAL_SYSTEM_PROMPT` 交给 Hermes（未确认 `-q` 读它，
/// 读不到只是 agent 不知道自己来自手机，不影响任务本身）。
public actor HermesConnector: TaskConnector {
    public nonisolated var kind: ConnectorKind { .hermes }

    /// 等 `system/init`（里面才有 session id）的上限。命令回执只表示"后端已接受"。
    static let sessionIDTimeout: TimeInterval = 20
    /// 内存里最多记多少个自己起过的会话（只用来兜底续聊的目录与标题）。
    static let maxSessions = 200
    static let ephemeralPromptVariable = "HERMES_EPHEMERAL_SYSTEM_PROMPT"

    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "hermes")

    /// 本连接器起过的一个会话。
    struct Session: Sendable {
        var sessionID: String
        var projectPath: String
        var title: String
        var status: TaskStatus
        var origin: TaskOrigin
        var lastMessage: String?
        var startedAt: String
        var updatedAt: String
    }

    /// 正在跑的一轮。`runID` 区分同一会话先后几轮的子进程，免得上一轮迟到的退出把这一轮收尾。
    private struct Run {
        var runID: UUID
        var process: any HermesRunningProcess
    }

    private let store: TaskStore
    private let paths: @Sendable () -> HermesPaths
    private let binary: @Sendable () -> String?
    private let launcher: any HermesProcessLauncher
    private let directoryProbe: DirectoryProbe
    private let now: @Sendable () -> Date
    private let tools: @Sendable () -> AgentToolsConfiguration?
    private let registry: TaskContextRegistry
    private let onRunFinished: @Sendable () async -> Void

    private var sessions: [String: Session] = [:]
    /// session id → 正在跑的那一轮。桌面上用户自己开的会话不在这里。
    private var runs: [String: Run] = [:]
    /// 已经在起子进程、还没拿到 session id 的会话（续聊用）：挡住同一会话的并发续聊。
    private var launching: Set<String> = []
    /// 子进程退出得比 `start` / `followUp` 登记这一轮还早（一轮极快、或 init 与 result 同一批到达）时先存这里。
    private var earlyFinishes: [UUID: HermesStreamReader.Result] = [:]
    /// 正在 `begin` 里登记的轮次。期间到达的 `finish` 先进 `earlyFinishes`，登记完再处理。
    private var registering: Set<UUID> = []
    /// 见 `finish` 里的兜底 release。
    static let releaseRetryDelay: TimeInterval = 1

    /// - Parameters:
    ///   - launcher: 起子进程的方式。测试注入假的，永远不跑真的 `hermes`。
    ///   - tools: 每次起子进程时现取；nil 或不可用 = 不注入 agent 工具。
    ///   - onRunFinished: 一轮结束、所有权交还之后调用。app 在这里催 Hermes 观察者 `pollOnce()`。
    public init(store: TaskStore,
                paths: @escaping @Sendable () -> HermesPaths = { HermesPaths() },
                binary: @escaping @Sendable () -> String? = { HermesPaths.detectHermesBinary() },
                launcher: any HermesProcessLauncher = HermesSubprocessLauncher(),
                directoryProbe: DirectoryProbe = .live(),
                now: @escaping @Sendable () -> Date = { Date() },
                tools: @escaping @Sendable () -> AgentToolsConfiguration? = { nil },
                registry: TaskContextRegistry = TaskContextRegistry(),
                onRunFinished: @escaping @Sendable () async -> Void = {}) {
        self.store = store
        self.paths = paths
        self.binary = binary
        self.launcher = launcher
        self.directoryProbe = directoryProbe
        self.now = now
        self.tools = tools
        self.registry = registry
        self.onRunFinished = onRunFinished
    }

    /// 停连接器：终止我们自己起的子进程。它们的退出照常走 `finish`，把任务写成最终状态并交还所有权。
    public func stop() {
        for run in runs.values { run.process.terminate() }
    }

    // MARK: - TaskConnector

    public func start(projectPath: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        // 协议 2.9 的手机发图本期只接了 Codex 与 Claude；明说不支持，别只发文字让用户以为 agent 看过图。
        guard images.isEmpty else { throw ConnectorError("这个 Agent 暂不支持发图") }
        let injection = await AgentToolsInjection.make(tools(), registry: registry)
        let runID = UUID()
        let (sessionID, process) = try await run(runID: runID,
                                                 arguments: Self.arguments(prompt: prompt, projectPath: projectPath, resuming: nil),
                                                 workingDirectory: projectPath, injection: injection)
        let timestamp = ProtocolJSON.timestamp(now())
        let session = Session(sessionID: sessionID, projectPath: projectPath,
                              title: Self.title(prompt: prompt, projectPath: projectPath),
                              status: .running, origin: .watch, startedAt: timestamp, updatedAt: timestamp)
        let stillRunning = await begin(session, runID: runID, process: process, injection: injection)
        return ConnectorOutcome(taskId: sessionID, retainsLiveOwnership: stillRunning)
    }

    public func followUp(taskId: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        guard images.isEmpty else { throw ConnectorError("这个 Agent 暂不支持发图") }
        let sessionID = try nativeTaskId(taskId, kind: .hermes)
        guard runs[sessionID] == nil, !launching.contains(sessionID) else {
            throw ConnectorError("这个会话还在跑，等这一轮结束再续聊")
        }
        // 第一个 await 之前就占位，否则两条并发续聊都能通过上面的检查、各起一个进程写同一个会话。
        launching.insert(sessionID)
        defer { launching.remove(sessionID) }
        let existing = await store.task(id: self.taskId(for: sessionID))
        if let existing, existing.status == .running, existing.origin == .desktop {
            // 桌面上正开着的会话：`--resume` 会和它抢同一个会话。
            throw ConnectorError("这个会话正在电脑上运行，等它停下再续聊")
        }
        let reader = HermesStateReader(paths: paths(), now: now)
        guard let workingDirectory = reader.cwd(forSession: sessionID) ?? sessions[sessionID]?.projectPath
                ?? existing.map(\.workingDirectory).flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw ConnectorError("找不到这个 Hermes 会话的项目目录")
        }

        // 续聊沿用这条任务之前的 token（agent 若把它记在了别处也照样有效）。
        let injection = await AgentToolsInjection.make(tools(), registry: registry, reusing: self.taskId(for: sessionID))
        let runID = UUID()
        let (newID, process) = try await run(runID: runID,
                                             arguments: Self.arguments(prompt: prompt, projectPath: workingDirectory,
                                                                       resuming: sessionID),
                                             workingDirectory: workingDirectory, injection: injection)

        let timestamp = ProtocolJSON.timestamp(now())
        let session: Session
        if newID == sessionID {
            // 同一个会话接着聊：标题、来源、开始时间都沿用，只把状态推回 running。
            let known = sessions[sessionID]
            session = Session(sessionID: sessionID, projectPath: workingDirectory,
                              title: known?.title ?? existing?.title ?? Self.title(prompt: prompt, projectPath: workingDirectory),
                              status: .running, origin: known?.origin ?? existing?.origin ?? .watch,
                              lastMessage: known?.lastMessage ?? existing?.lastMessage,
                              startedAt: known?.startedAt ?? existing?.startedAt ?? timestamp, updatedAt: timestamp)
        } else {
            // `--resume` 分出了新会话（同 Claude 的分支）：当成手机上新开的一条，回执给新 id。
            session = Session(sessionID: newID, projectPath: workingDirectory,
                              title: Self.title(prompt: prompt, projectPath: workingDirectory),
                              status: .running, origin: .watch, startedAt: timestamp, updatedAt: timestamp)
        }
        let stillRunning = await begin(session, runID: runID, process: process, injection: injection)
        return ConnectorOutcome(taskId: newID, retainsLiveOwnership: stillRunning)
    }

    public func approve(taskId: String, requestId: String,
                        decision: Command.Approve.Decision) async throws -> ConnectorOutcome {
        throw ConnectorError("Hermes 的 -q 模式没有审批通道：危险命令会按它自己的 approvals.single_query_mode 处理，请在电脑上操作")
    }

    public func interrupt(taskId: String) async throws -> ConnectorOutcome {
        let sessionID = try nativeTaskId(taskId, kind: .hermes)
        guard let run = runs[sessionID] else {
            // 桌面上用户自己开的会话不是我们的子进程，发不了信号。
            throw ConnectorError("这个会话是在电脑上启动的，只能在电脑上中断")
        }
        run.process.interrupt()
        if var session = sessions[sessionID] {
            session.status = .interrupted
            session.updatedAt = ProtocolJSON.timestamp(now())
            sessions[sessionID] = session
            await store.upsert(record(session))
        }
        // 所有权仍由这一轮持有，等子进程真的退出（`finish`）再交还。
        return ConnectorOutcome(taskId: sessionID, retainsLiveOwnership: true)
    }

    // MARK: - 一轮的开始与结束

    /// 登记这一轮：认领所有权、推 running、绑 token。子进程若已经抢先退出，登记完再收尾。
    ///
    /// 登记期间有好几个 `await`，actor 会在那里重入：`finish` 若趁机插进来写了最终状态，
    /// 这里随后那句 `upsert(running)` 就会把它盖回去。所以登记没做完之前，`finish` 一律只排队。
    ///
    /// 返回这一轮是否还在跑。已经跑完时就地收尾但**不交还**所有权：分发器拿到 `retainsLiveOwnership: false`
    /// 会自己 claim 再 release，我们先 release 的话它随后那一手 claim 就再也没人放了。
    @discardableResult
    private func begin(_ session: Session, runID: UUID, process: any HermesRunningProcess,
                       injection: AgentToolsInjection?) async -> Bool {
        let id = taskId(for: session.sessionID)
        sessions[session.sessionID] = session
        runs[session.sessionID] = Run(runID: runID, process: process)
        registering.insert(runID)
        pruneIfNeeded()
        await store.claimLive(id)
        await store.upsert(record(sessions[session.sessionID] ?? session))
        if let injection { await registry.bind(injection.token, taskId: id) }
        registering.remove(runID)
        if let early = earlyFinishes.removeValue(forKey: runID) {
            await finish(runID: runID, result: early, releasing: false)
            return false
        }
        return true
    }

    /// 子进程退出后的收尾：写最终状态（被 interrupt 标过的不改回 completed）、交还所有权、催观察者。
    private func finish(runID: UUID, result: HermesStreamReader.Result, releasing: Bool = true) async {
        guard let sessionID = result.sessionID else { return }
        if registering.contains(runID) {
            earlyFinishes[runID] = result
            return
        }
        guard let run = runs[sessionID], run.runID == runID, var session = sessions[sessionID] else {
            // 还没登记（`begin` 会来取），或者属于早已被替换掉的一轮（直接丢弃）。
            if runs[sessionID]?.runID != runID { earlyFinishes[runID] = result }
            return
        }
        runs.removeValue(forKey: sessionID)
        if session.status != .interrupted { session.status = result.failed ? .failed : .completed }
        let text = result.lastText?.trimmed.nilIfEmpty ?? (result.failed ? result.errorMessage?.trimmed.nilIfEmpty : nil)
        if let text { session.lastMessage = SessionFormatting.truncate(text, SessionFormatting.lastMessageLimit) }
        session.updatedAt = ProtocolJSON.timestamp(now())
        sessions[sessionID] = session
        await store.upsert(record(session))
        if releasing {
            let id = taskId(for: sessionID)
            await store.releaseLive(id)
            // 兜底（同 Pi）：分发器在命令返回**之后**才 claim。这一轮若恰好在"回执已返回、分发器还没 claim"
            // 的空当里结束，这次 release 会先于那次 claim，所有权就永远卡在 live。过一会儿再放一次；
            // 期间若已有新一轮在跑就不动（它自己拿着所有权）。
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.releaseRetryDelay))
                await self?.releaseIfIdle(sessionID: sessionID, taskId: id)
            }
        }
        await onRunFinished()
    }

    private func releaseIfIdle(sessionID: String, taskId: String) async {
        guard runs[sessionID] == nil, !launching.contains(sessionID) else { return }
        await store.releaseLive(taskId)
    }

    private func record(_ session: Session) -> TaskRecord {
        TaskRecord(id: taskId(for: session.sessionID),
                   agentId: "",
                   source: .hermes,
                   title: session.title,
                   projectPath: session.projectPath,
                   projectName: SessionFormatting.projectName(session.projectPath),
                   status: session.status,
                   lastMessage: session.lastMessage,
                   origin: session.origin,
                   // 自己起的这一轮能中断、跑完能续聊，所以一律可控；桌面上正在跑的由观察者标成不可控。
                   controllable: true,
                   startedAt: session.startedAt,
                   updatedAt: session.updatedAt)
    }

    private func pruneIfNeeded() {
        guard sessions.count > Self.maxSessions else { return }
        let doomed = sessions.values
            .filter { runs[$0.sessionID] == nil }
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(sessions.count - Self.maxSessions)
        for session in doomed { sessions.removeValue(forKey: session.sessionID) }
    }

    static func title(prompt: String, projectPath: String) -> String {
        let title = SessionFormatting.truncate(HermesStateReader.singleLine(prompt), SessionFormatting.titleLimit)
        if !title.isEmpty { return title }
        let name = SessionFormatting.projectName(projectPath)
        return name.isEmpty ? "Hermes 会话" : name
    }

    // MARK: - 子进程

    /// `hermes` 的完整参数：`chat -q <prompt> --format stream-json --in <目录> [--resume <id>]`。
    /// prompt 紧跟 `-q` 作为它的值，以 `-` 开头的 prompt 也不会被当成选项。
    static func arguments(prompt: String, projectPath: String, resuming sessionID: String?) -> [String] {
        var arguments = ["chat", "-q", prompt, "--format", "stream-json", "--in", projectPath]
        if let sessionID { arguments += ["--resume", sessionID] }
        return arguments
    }

    /// 注入的环境变量：三个 `BOTBUS_*` 加上给 Hermes 的一次性系统提示。没有注入就是空表。
    static func injectedEnvironment(_ injection: AgentToolsInjection?) -> [String: String] {
        guard let injection else { return [:] }
        var environment = injection.environment
        environment[ephemeralPromptVariable] = injection.cliOnlyInstructions
        return environment
    }

    /// 起一个 `hermes chat -q …` 并**只等到 session id 出现就返回**；剩下的输出在后台接着读，用来把任务推进到结束。
    private func run(runID: UUID, arguments: [String], workingDirectory: String,
                     injection: AgentToolsInjection?) async throws -> (String, any HermesRunningProcess) {
        guard let executable = binary() else {
            throw ConnectorError("本机没找到 hermes 可执行文件", diagnosis: .agentNotInstalled)
        }
        if let diagnosis = await directoryProbe.diagnose(workingDirectory) {
            throw ConnectorError.directory(diagnosis, path: workingDirectory)
        }

        let request = HermesLaunchRequest(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            // Hermes 装在 uv / pipx 的 bin 目录里，GUI 进程的 PATH 未必有它的依赖；把它所在目录补到最前。
            environment: AgentBinary.environment(for: executable, adding: Self.injectedEnvironment(injection)))
        let sessionID = OneShotContinuation<String>()
        let parser = HermesStreamParserBox()
        let process: any HermesRunningProcess
        do {
            process = try launcher.launch(request, output: { data in
                if let id = parser.consume(data) { sessionID.resume(returning: id) }
            }, exit: { [weak self] status in
                let result = parser.finish(exitStatus: status)
                // 一行 init 都没吐出来就退了：别让调用方一直等到超时。
                sessionID.resume(throwing: ConnectorError(result.errorMessage.map { "hermes 退出了，没有拿到 session id：\($0)" }
                                                          ?? "hermes 退出了，没有拿到 session id"))
                Task { await self?.finish(runID: runID, result: result) }
            })
        } catch {
            throw ConnectorError("起不了 hermes：\(error.localizedDescription)")
        }

        let timer = Task {
            try? await Task.sleep(for: .seconds(Self.sessionIDTimeout))
            sessionID.resume(throwing: ConnectorError("等 hermes 回应超时"))
        }
        defer { timer.cancel() }
        do {
            return (try await sessionID.value(), process)
        } catch {
            // 没拿到 id 的一轮没人认领，也没法再中断：别让它在后台接着跑。
            process.terminate()
            throw error
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - 子进程抽象

/// 起一个 `hermes` 需要的全部信息。
public struct HermesLaunchRequest: Sendable, Hashable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    /// 完整环境（不是增量）。
    public var environment: [String: String]

    public init(executable: String, arguments: [String], workingDirectory: String, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

/// 一个跑着的 `hermes`。
public protocol HermesRunningProcess: Sendable {
    /// SIGINT：让 Hermes 像在终端里按了 Ctrl-C 一样收尾。
    func interrupt()
    /// SIGTERM：停机或放弃这一轮时用。
    func terminate()
}

/// 起子进程的方式。契约：`output` 按到达顺序送 stdout 的数据块；`exit` 恰好调一次，
/// 且在已读到的 stdout 都送完之后（进程退出码作参数）。两个回调都可能在任意线程上。
public protocol HermesProcessLauncher: Sendable {
    func launch(_ request: HermesLaunchRequest,
                output: @escaping @Sendable (Data) -> Void,
                exit: @escaping @Sendable (Int32) -> Void) throws -> any HermesRunningProcess
}

/// 真的起 `Process`。stdin 接空设备（`-q` 不该读终端；万一它要确认什么，读到 EOF 也比永远挂着强），
/// stderr 丢弃（不读的 Pipe 写满 64 KB 会把子进程卡死）。
public struct HermesSubprocessLauncher: HermesProcessLauncher {
    /// 进程退出后最多再等 stdout 的 EOF 这么久。Hermes 在终端工具里起的后台进程会继承 stdout，
    /// 它们不退，EOF 就永远不来；不设上限的话这一轮永远收不了尾。
    static let drainTimeout: TimeInterval = 2

    public init() {}

    public func launch(_ request: HermesLaunchRequest,
                       output: @escaping @Sendable (Data) -> Void,
                       exit: @escaping @Sendable (Int32) -> Void) throws -> any HermesRunningProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let completion = ExitCoordinator(exit)
        let handle = stdout.fileHandleForReading
        handle.portableReadabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // 不只摘 handler：Linux 上还得关读端，否则每一轮 hermes 漏一个描述符。
                handle.finishPortableReading()
                completion.sawEOF()
            } else {
                output(chunk)
            }
        }
        process.terminationHandler = { process in
            completion.terminated(process.terminationStatus)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainTimeout) {
                // EOF 迟迟不来：不再等了（之后再到的数据块会被解析器忽略），读端一并收掉。
                handle.finishPortableReading()
                completion.sawEOF()
            }
        }
        do {
            try process.run()
        } catch {
            handle.finishPortableReading()
            try? stdout.fileHandleForWriting.close()
            throw error
        }
        return HermesSubprocess(process: process)
    }

    /// 等"读到 EOF"与"进程退出"两件事都发生了才调 `exit`，且只调一次。
    private final class ExitCoordinator: @unchecked Sendable {
        private let lock = NSLock()
        private var eof = false
        private var status: Int32?
        private var done = false
        private let exit: @Sendable (Int32) -> Void

        init(_ exit: @escaping @Sendable (Int32) -> Void) { self.exit = exit }

        func sawEOF() { update { $0.eof = true } }
        func terminated(_ code: Int32) { update { $0.status = code } }

        private func update(_ change: (ExitCoordinator) -> Void) {
            lock.lock()
            change(self)
            let fire: Int32? = (!done && eof) ? status : nil
            if fire != nil { done = true }
            lock.unlock()
            if let fire { exit(fire) }
        }
    }
}

private final class HermesSubprocess: HermesRunningProcess, @unchecked Sendable {
    private let process: Process

    init(process: Process) { self.process = process }

    func interrupt() {
        guard process.isRunning else { return }
        PlatformProcess.interrupt(process.processIdentifier)
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }
}

// MARK: - stream-json

/// 解析器加一把锁：`output` 与 `exit` 回调来自不同线程。
private final class HermesStreamParserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reader = HermesStreamReader()

    /// 返回这一块里新出现的 session id（只报第一次）。
    func consume(_ data: Data) -> String? { lock.withLock { reader.consume(data) } }

    func finish(exitStatus: Int32) -> HermesStreamReader.Result { lock.withLock { reader.finish(exitStatus: exitStatus) } }
}

/// 读 `hermes chat -q … --format stream-json` 的 stdout：一行一个 JSON 对象。
///
/// 只关心三件事：
/// - `{"type":"system","subtype":"init","session_id":…}` —— 会话 id，命令回执等的就是它；
/// - `{"type":"text","text":…}` —— **增量**文本，拼起来；遇到 `tool_use` / `tool_result` 就重新开始攒，
///   这样留下的是最后一次工具调用之后的那段（也就是最终回答）；
/// - `{"type":"result","session_id","exit_code","text","error"?}` —— 一轮结束。
///
/// 其余类型忽略。**解析全程容错**：多一种没见过的行、一行坏 JSON，都不该让整轮白跑。
struct HermesStreamReader: Sendable {
    struct Result: Sendable, Equatable {
        var sessionID: String?
        var lastText: String?
        /// `result` 报了错、退出码非 0，或者根本没等到 `result`。
        var failed: Bool
        var errorMessage: String?
    }

    /// 一行没结束就一直攒；超过这个上限说明流坏了，丢掉免得把内存吃光。
    static let maxLineBytes = 8 << 20

    private var buffer = Data()
    private var sessionID: String?
    private var streamedText = ""
    private var resultText: String?
    private var sawResult = false
    private var resultFailed = false
    private var errorMessage: String?
    private var finished = false

    init() {}

    /// 喂一块 stdout。返回这一块里第一次出现的 session id。
    mutating func consume(_ data: Data) -> String? {
        guard !finished else { return nil }
        buffer.append(data)
        var found: String?
        while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<index]
            buffer = Data(buffer[buffer.index(after: index)...])
            if let id = handle(line: line) { found = found ?? id }
        }
        if buffer.count > Self.maxLineBytes { buffer.removeAll(keepingCapacity: false) }
        return found
    }

    /// 进程退出：处理最后一行没带换行的残余，给出这一轮的结论。幂等，之后再喂的数据一律忽略。
    mutating func finish(exitStatus: Int32) -> Result {
        if !finished, !buffer.isEmpty {
            _ = handle(line: buffer)
            buffer.removeAll()
        }
        finished = true
        let text = resultText?.trimmed.isEmpty == false ? resultText : (streamedText.trimmed.isEmpty ? nil : streamedText)
        let failed = resultFailed || !sawResult || exitStatus != 0
        var message = errorMessage
        if failed, message == nil {
            message = !sawResult ? "hermes 没有正常结束（退出码 \(exitStatus)）" : (exitStatus != 0 ? "hermes 退出码 \(exitStatus)" : nil)
        }
        return Result(sessionID: sessionID, lastText: text?.trimmed, failed: failed, errorMessage: message)
    }

    /// 一行 → 新出现的 session id（如有）。
    private mutating func handle(line: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "system":
            let subtype = object["subtype"] as? String
            guard subtype == nil || subtype == "init", sessionID == nil,
                  let id = (object["session_id"] as? String)?.trimmed, !id.isEmpty else { return nil }
            sessionID = id
            return id
        case "text":
            if let text = object["text"] as? String { streamedText += text }
        case "tool_use", "tool_result":
            streamedText = ""
        case "result":
            sawResult = true
            if let text = object["text"] as? String { resultText = text }
            if let code = Self.integer(object["exit_code"]), code != 0 { resultFailed = true }
            if let error = Self.errorText(object["error"]) {
                resultFailed = true
                errorMessage = error
            }
            // 极端情况下 init 没来、result 带了 id：也认。
            if sessionID == nil, let id = (object["session_id"] as? String)?.trimmed, !id.isEmpty {
                sessionID = id
                return id
            }
        default:
            break
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// `error` 可能是字符串，也可能是 `{message: …}`；空串 / null / false 不算错。
    private static func errorText(_ value: Any?) -> String? {
        if let text = (value as? String)?.trimmed, !text.isEmpty { return text }
        if let object = value as? [String: Any] {
            return (object["message"] as? String)?.trimmed.nilIfEmpty ?? "hermes 报错"
        }
        return nil
    }
}
