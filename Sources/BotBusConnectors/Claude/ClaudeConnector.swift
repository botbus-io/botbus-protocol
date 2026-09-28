import Foundation
import os
import BotBusProtocol
import BotBusConnectorKit

/// Claude Code 连接器：hooks 负责"看见"，`claude -p` 负责"动手"。
///
/// 和 Codex 那边的形状完全不同，因为 Claude Code 没有 app-server：
/// - **看见**：用户装上 hooks 之后，Claude Code 在会话开始、提问、请求权限、空闲、停止、报错结束、会话退出时
///   各打一次本机回环 HTTP（`LocalHookServer`），本连接器把它们映射成 Task 状态。电脑上按停止没有 hook，
///   靠盯 transcript 末尾的中断标记补上（`checkTurnEndings`）。
/// - **动手**：`startTask` / `followUp` 各起一个 `claude -p` 子进程，从 stream-json 里认领 session id。
/// - **补历史**：hooks 只看得见启动之后有动静的会话，所以每次启动时 `restoreRecentSessions()`
///   从 transcript 补回 7 天内的会话（`ClaudeSessionHistory`），只做一次，不轮询。
/// - **跟标题**：桌面 app 与 Claude Code 会给会话起名并写进 transcript，hook 负载里却没有。
///   hook 进来时顺手去 transcript 末尾看一眼（`refreshAppTitle`），标题跟 app 侧栏保持一致。
///
/// **所有权一拿就不放**：Claude 这一侧没有只读观察者（不像 Codex 有 `CodexObserver`），
/// 本连接器就是唯一权威，所以每个会话建出来就 `claimLive`，不再交还——
/// 交还了反而会被"该来源报告了空列表"的对账当成消失。
///
/// **手机任务带上 agent 工具**（spec 3.2）：`start` / `followUp` 都来自手机，app 给了可用的
/// `AgentToolsConfiguration` 时，子进程多三个环境变量与 `--append-system-prompt` / `--mcp-config` /
/// `--allowedTools`，session id 一到手就把 token 绑到任务上（`--resume` 分支出的新 id 也绑）。
public actor ClaudeConnector: TaskConnector {
    public nonisolated var kind: ConnectorKind { .claude }

    /// 内存里最多留多少个会话。超了丢最旧的——分片上限本来就是 200 条，留更多也传不出去。
    static let maxSessions = 200
    /// 等 `claude -p` 吐出 `system/init`（里面才有 session id）的上限。
    /// 命令回执只表示"后端已接受"，不该为了它等一整轮。
    static let sessionIDTimeout: TimeInterval = 20
    /// `claude` 一行 init 都没吐就退出了（参数不认、没登录……）。新建时认它来决定要不要去掉 `--name` 重起。
    static let exitedWithoutSessionID = ConnectorError("claude 退出了，没有拿到 session id")
    /// 标题上限，对齐协议里 Claude 取首条 prompt 截断 80 字。
    static let titleLimit = 80
    /// 只发图、不写字新建任务时的标题，与 `CodexConnector.imageOnlyTitle` 一致。仍记为占位，之后第一条带字的 prompt 会换掉它。
    static let imageOnlyTitle = "图片"
    static let lastMessageLimit = 500
    static let detailLimit = 2000
    /// 等 Claude 起名落盘的节奏（秒，每次尝试前先等这么久）。起名在第一条 prompt 之后异步进行，
    /// 这一轮里可能再没有别的 hook，所以追着看几次，累计约 100 秒。
    static let titleRetryDelays: [TimeInterval] = [0, 3, 10, 30, 60]
    /// 电脑上的会话还在跑时，隔多久看一眼 transcript 末尾有没有收尾标记（见 `checkTurnEndings`）。
    static let turnEndCheckInterval: TimeInterval = 30
    /// 收尾标记的时间比这一轮开始（Agent 收到 hook 的时刻）早多少以内仍算这一轮的。
    /// 更早的是上一轮留下的，不算。
    static let turnEndSlack: TimeInterval = 2

    private static let log = Logger(subsystem: "io.botbus.agent", category: "claude")

    /// 标题从哪来。排后面的顶掉排前面的；Claude 起的名字同级也会被新值顶掉（桌面 app 里改了名）。
    enum TitleSource: Int, Comparable, Sendable {
        /// 项目名或「图片」占位——第一条带字的 prompt 来了要换掉。
        case placeholder
        /// 第一条 prompt 截断。
        case prompt
        /// Claude Code 自己生成的 `ai-title`（命令行、`claude -p` 会话）。
        case generated
        /// 桌面 app 侧栏上的标题（`custom-title`，app 起的或用户改的）。
        case named

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// 带着这个来源的新标题该不该顶掉 `current` 来源的旧标题。
        /// prompt 同级不换：标题是"这个会话在干什么"，不是"最后一句话"。
        func replaces(_ current: TitleSource) -> Bool {
            self > current || (self == current && self >= .generated)
        }
    }

    /// 一个 Claude 会话在本连接器眼里的全部状态。Task 由它算出来，而不是反过来。
    struct Session: Sendable {
        var sessionID: String
        var projectPath: String
        var title: String
        var titleSource: TitleSource
        var status: TaskStatus
        var origin: TaskOrigin
        var lastMessage: String?
        var pendingRequest: PendingRequest?
        var startedAt: String
        var updatedAt: String
        /// hook 报过的 transcript 路径；看收尾标记要用。
        var transcriptPath: String?
        /// 这一轮从什么时候算起：进入 running / waitingApproval 的时刻。
        var turnStartedAt: Date?
        /// transcript 里最近一次用的模型（`ClaudeModels` 的别名），只用来显示。
        var model: String?
        /// 协议 3.2：手机选过的模型与思考强度。之后每次 `--resume` 都带上——`claude -p` 不记得上一轮的 `--model`。
        var chosenModel: String?
        var chosenEffort: String?

        /// 一轮正跑着：没有 hook 能保证把它收尾（中断不发 Stop），得盯着。
        var isMidTurn: Bool { status == .running || status == .waitingApproval }
    }

    private let store: TaskStore
    private let paths: ClaudePaths
    private let binary: @Sendable () -> String?
    /// 本机 `claude --help` 认的强度；nil = CLI 不可用，不报 models。
    private let supportedEfforts: [String]?
    private let now: @Sendable () -> Date
    private let tools: @Sendable () -> AgentToolsConfiguration?
    private let registry: TaskContextRegistry

    private var sessions: [String: Session] = [:]
    /// 挂起的 `PermissionRequest`：requestId → 那条还没回的 HTTP 响应。
    private var holds: [String: LocalHookServer.Hold] = [:]
    /// 其中是 `AskUserQuestion` 的那些：requestId → 哪个会话、问了什么（回答时要原样带回入参）。
    private var questionHolds: [String: QuestionHold] = [:]

    struct QuestionHold: Sendable {
        var sessionID: String
        var asked: ClaudeAskedQuestions
    }
    /// 我们自己起的子进程，`interrupt` 要靠它发 SIGINT。桌面上用户自己开的会话不在这里。
    private var ownProcesses: [String: Process] = [:]
    /// 自己那一轮还在跑时到达的续聊，按 session 排队；上一轮结束（`finish`）后依次 `--resume`。
    private var queued: [String: [QueuedTurn]] = [:]
    /// 正在起 `--resume`、还没拿到 session id 的会话。这几秒里 `ownProcesses` 还没登记，
    /// 期间到达的续聊同样要排队（actor 在等 id 时会重入）。
    private var launching: Set<String> = []
    /// `--resume` 分支出新 session 后，旧 session id 就放在这里。
    /// 之后从桌面来的 hook 事件照样带着旧 id，如果放行就会把旧会话重新拉进列表，
    /// 用户在手机上又看到两条——所以这里拦截，让旧会话安静地留在电脑上。
    private var superseded: Set<String> = []

    /// 一条排队的续聊。图在收到时就读好（读不到当场报错），轮到它时直接写进 stdin。
    struct QueuedTurn: Sendable {
        var prompt: String
        var input: Data?
        var hasImages: Bool
        /// 这一轮的 `--model` / `--effort`，收到时就定下来（排队期间再换，只影响之后收到的续聊）。
        var model: String? = nil
        var effort: String? = nil
    }
    /// 正在追 transcript 标题的会话。同一会话同时只跑一个。
    private var titleRefreshes: [String: Task<Void, Never>] = [:]
    /// 不认 `--name` 的 claude（软链接解析到底的路径）：之后新建时直接不带名字，免得每次多起一个失败的进程。
    /// 升级后路径变了，自然再试一次。
    private var binaryWithoutName: String?
    private let titleRetryDelays: [TimeInterval]
    /// 盯收尾标记的循环；没有要盯的会话时自己退出。
    private var turnEndCheck: Task<Void, Never>?
    private let turnEndCheckInterval: TimeInterval
    /// 各别名见过的最新版本，撑起手机上「Opus 5.5」里的版本号（见 `ClaudeModels`）。
    /// 初始为空——启动时补历史会话就会从 transcript 里填上常用模型的版本。
    private var modelVersions: [String: [Int]] = [:]
    /// 模型列表改过、还没随快照发出去（任务事件不带连接器信息）。
    private var modelsChanged = false

    /// - Parameters:
    ///   - tools: 每次起子进程时现取；nil 或不可用 = 不注入 agent 工具。
    ///   - registry: 签发与绑定 task token；app 里与本机工具服务器共用同一个实例。
    ///   - titleRetryDelays: nil = `ClaudeConnector.titleRetryDelays`；测试传短的。
    ///   - turnEndCheckInterval: nil = `ClaudeConnector.turnEndCheckInterval`；测试传短的。
    public init(store: TaskStore,
                paths: ClaudePaths = ClaudePaths(),
                binary: @escaping @Sendable () -> String? = { ClaudePaths.detectClaudeBinary() },
                now: @escaping @Sendable () -> Date = { Date() },
                tools: @escaping @Sendable () -> AgentToolsConfiguration? = { nil },
                registry: TaskContextRegistry = TaskContextRegistry(),
                titleRetryDelays: [TimeInterval]? = nil,
                turnEndCheckInterval: TimeInterval? = nil) {
        self.store = store
        self.paths = paths
        self.binary = binary
        self.supportedEfforts = ClaudeModels.efforts(forBinary: binary())
        self.now = now
        self.tools = tools
        self.registry = registry
        self.titleRetryDelays = titleRetryDelays ?? Self.titleRetryDelays
        self.turnEndCheckInterval = turnEndCheckInterval ?? Self.turnEndCheckInterval
        store.connectors.setModels(supportedEfforts.map { ClaudeModels.options(versions: [:], efforts: $0) },
                                   for: .claude)
    }

    /// 报给手机的模型列表：版本号来自见过的 transcript，强度来自本机 CLI。
    private var modelOptions: [ModelOption]? {
        supportedEfforts.map { ClaudeModels.options(versions: modelVersions, efforts: $0) }
    }

    /// 停连接器：放掉所有挂起的审批（让 Claude Code 回落到自己的弹窗，而不是干等 120 秒），
    /// 并终止我们自己起的子进程。
    public func stop() {
        for hold in holds.values { hold.answer(.noContent) }
        holds.removeAll()
        questionHolds.removeAll()
        queued.removeAll()
        for process in ownProcesses.values where process.isRunning { process.terminate() }
        ownProcesses.removeAll()
        superseded.removeAll()
        for refresh in titleRefreshes.values { refresh.cancel() }
        titleRefreshes.removeAll()
        turnEndCheck?.cancel()
        turnEndCheck = nil
    }

    /// 见到一个完整模型名：版本比记着的新就更新手机上的模型列表，下一次 `publish` 补发快照。
    private func noteModel(_ name: String) {
        guard ClaudeModels.note(transcriptModel: name, in: &modelVersions), let modelOptions,
              store.connectors.setModels(modelOptions, for: .claude) else { return }
        modelsChanged = true
    }

    // MARK: - Hook 入口

    /// `LocalHookServer` 把 `/hooks/claude` 的请求交到这里。
    ///
    /// 除 `PermissionRequest` 之外一律立刻回空——hook 脚本挂在 Claude Code 的主流程上，
    /// 多等一毫秒都是在拖慢用户敲下回车之后的反应。
    public func handleHook(_ request: LocalHookServer.Request) async -> LocalHookServer.Reply {
        guard let event = ClaudeHookEvent(json: request.body) else { return .now(.noContent) }
        guard !event.sessionID.isEmpty else { return .now(.noContent) }
        // 被分支取代的旧会话：桌面 hook 继续来，但 BotBus 不再管它。
        // 放行的话会重建已移除的会话，手机上又变成两条。
        guard !superseded.contains(event.sessionID) else { return .now(.noContent) }

        switch event.kind {
        case .sessionStart:
            // 打开、恢复（桌面 app 里点开一个旧会话就算）、`/clear`、压缩上下文都发 SessionStart，
            // 它不代表开始干活——干活从 UserPromptSubmit 算，否则点开过的会话会一直挂着"运行中"。
            // 所以状态不动、也不顶 updatedAt；没见过的会话不建（和补历史一样，不收没有 prompt 的空会话）。
            guard var session = sessions[event.sessionID] else { return .now(.noContent) }
            if let path = event.transcriptPath, !path.isEmpty { session.transcriptPath = path }
            sessions[event.sessionID] = session
            guard !event.cwd.isEmpty, event.cwd != session.projectPath else { return .now(.noContent) }
            apply(event) { session, event in session.projectPath = event.cwd }
        case .userPromptSubmit:
            apply(event) { session, event in
                session.status = .running
                session.pendingRequest = nil
                session.turnStartedAt = self.now()
                // 桌面 app 会在人敲的话前面拼几段 `<system-reminder>`，hook 拿到的是拼好的整串。
                if session.titleSource == .placeholder,
                   let prompt = event.prompt.map({ ClaudeMessageReader.stripInjectedBlocks($0).trimmed }),
                   !prompt.isEmpty {
                    session.title = String(prompt.prefix(Self.titleLimit))
                    session.titleSource = .prompt
                }
            }
        case .notification:
            switch event.notificationType {
            case "idle_prompt", "agent_needs_input":
                apply(event) { session, _ in session.status = .waitingInput }
            default:
                // `permission_prompt` 与 PermissionRequest 说的是同一件事，那边已经建过
                // pendingRequest 了；在这儿再动一次只会多推一条通知。其余类型与任务状态无关。
                return .now(.noContent)
            }
        case .stop:
            let name = event.transcriptPath.flatMap { ClaudeModels.lastModel(inTranscriptAt: $0) }
            if let name { noteModel(name) }
            let model = name.flatMap { ClaudeModels.optionId(forTranscriptModel: $0) }
            apply(event) { session, event in
                session.status = .completed
                session.pendingRequest = nil
                if let text = self.finalMessage(for: event) { session.lastMessage = text }
                if let model { session.model = model }
            }
        case .stopFailure:
            apply(event) { session, event in
                session.status = .failed
                session.pendingRequest = nil
                if let text = (event.lastAssistantMessage ?? event.errorDetails ?? event.error)?.trimmed, !text.isEmpty {
                    session.lastMessage = String(text.prefix(Self.lastMessageLimit))
                }
            }
        case .sessionEnd:
            return await endSession(event)
        case .permissionRequest:
            return await holdForApproval(event)
        }
        await publish()
        return .now(.noContent)
    }

    /// `SessionEnd`：会话进程退出了。一轮跑到一半（含挂着审批、提问）被关掉记 interrupted；
    /// 空闲等输入的记 completed——没人在等了。已经收尾的不动。
    /// 本连接器自己起的 `claude -p` 退出时也会发，那边由 `finish` 按进程结果收尾，这里不插手。
    private func endSession(_ event: ClaudeHookEvent) async -> LocalHookServer.Reply {
        guard let session = sessions[event.sessionID], !isOwnTurn(event.sessionID) else { return .now(.noContent) }
        let cutOff = session.isMidTurn || (session.status == .waitingInput && session.pendingRequest != nil)
        guard cutOff || session.status == .waitingInput else { return .now(.noContent) }
        releaseHold(for: session)
        apply(event) { session, _ in
            session.status = cutOff ? .interrupted : .completed
            session.pendingRequest = nil
        }
        // 关掉一个空闲会话不是"任务完成"，不推通知；interrupted 本来就不推。
        await publish(notify: false)
        return .now(.noContent)
    }

    /// 本连接器自己起的那一轮还没收尾（含起进程到拿到 session id 的几秒）。看登记而不是 `isRunning`：
    /// 进程退出到 `finish` 摘掉登记之间到达的 SessionEnd 若抢先记了 interrupted，`finish` 就改不回 completed 了。
    private func isOwnTurn(_ sessionID: String) -> Bool {
        launching.contains(sessionID) || ownProcesses[sessionID] != nil
    }

    /// 会话已经在电脑上收尾了，还挂着的审批 / 提问没人会再收：回空，把 hook 脚本放掉。
    private func releaseHold(for session: Session) {
        guard let requestID = session.pendingRequest?.id else { return }
        questionHolds.removeValue(forKey: requestID)
        holds.removeValue(forKey: requestID)?.answer(.noContent)
    }

    /// `PermissionRequest`：建 pendingRequest，然后把 HTTP 响应挂住，等手机上点允许或拒绝。
    ///
    /// 超时回落成"没有意见"（空响应），Claude Code 于是弹它自己的权限框——`-p` 模式下等同拒绝。
    /// 这正是 hook 脚本 `--max-time 120` 想要的行为，两边必须说同一件事。
    ///
    /// `AskUserQuestion` 不是"批不批"而是"选哪个"：建成带 `questions` 的 `.input` 请求，任务记 `waitingInput`，
    /// 手机选好了经 `approve` 带 `answers` 回来，或者直接打字经 `followUp` 回来（见 `answerQuestion`）。
    ///
    /// 协议 3.3：本连接器替手机跑的那一轮（`isOwnTurn`）里，会话所在项目开着自动批准时，审批直接回 `allow`，
    /// 不建 pendingRequest、不推通知；`AskUserQuestion` 照旧交给手机。电脑上自己跑的轮次不受影响。
    private func holdForApproval(_ event: ClaudeHookEvent) async -> LocalHookServer.Reply {
        if event.askedQuestions == nil, isOwnTurn(event.sessionID),
           await store.autoApproves(taskId: taskId(for: event.sessionID),
                                    workingDirectory: sessions[event.sessionID]?.projectPath ?? event.cwd) {
            Self.log.info("项目已开自动批准，放行 \(event.toolName ?? "权限请求", privacy: .public)")
            return .now(.json(ClaudeHookOutput.permission(allow: true, reason: "项目已开自动批准")))
        }
        let requestID = event.toolUseID ?? UUID().uuidString
        let summary = event.toolName ?? "请求权限"
        apply(event) { session, event in
            if let asked = event.askedQuestions {
                session.status = .waitingInput
                session.pendingRequest = PendingRequest(id: requestID, kind: .input, summary: asked.summary,
                                                        question: asked.plainText, questions: asked.questions)
            } else {
                session.status = .waitingApproval
                session.pendingRequest = PendingRequest(
                    id: requestID,
                    kind: .permission,
                    summary: summary,
                    detail: event.toolInput.map { String($0.prefix(Self.detailLimit)) })
            }
        }
        await publish()

        let hold = LocalHookServer.Hold(timeout: LocalHookServer.defaultHoldTimeout)
        holds[requestID] = hold
        if let asked = event.askedQuestions {
            questionHolds[requestID] = QuestionHold(sessionID: event.sessionID, asked: asked)
        }

        // hold 超时后只收掉 holds 里的条目（让 PermissionRequest 路径直接报错），
        // 但保留 questionHolds 和 pendingRequest：卡片不消失，
        // 用户迟到的回答能走 followUp 送进去。
        Task {
            try? await Task.sleep(for: .seconds(LocalHookServer.defaultHoldTimeout + 1))
            self.holds.removeValue(forKey: requestID)
        }

        return .hold(hold)
    }

    /// 取 Stop 时的最后一条 assistant 文本。2.1.273 起负载里直接带（`last_assistant_message`），
    /// 没有时才去读 transcript——读不到就留空，绝不因此让这条 hook 失败。
    private func finalMessage(for event: ClaudeHookEvent) -> String? {
        if let text = event.lastAssistantMessage?.trimmed, !text.isEmpty {
            return String(text.prefix(Self.lastMessageLimit))
        }
        guard let path = event.transcriptPath else { return nil }
        return Self.lastAssistantText(inTranscriptAt: path).map { String($0.prefix(Self.lastMessageLimit)) }
    }

    /// 从 JSONL transcript 末尾往回找最后一条 assistant 文本。整段容错：
    /// 文件不在、某一行不是 JSON、结构变了，都只是返回 nil。
    static func lastAssistantText(inTranscriptAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let text = assistantText(object) { return text }
        }
        return nil
    }

    /// Claude Code 自己往 transcript 里补的填充行，不是对话：resume 一个上一轮没跑完的会话时，
    /// 它先插一条 `isMeta` 的 "Continue from where you left off."，再配一条 `model: "<synthetic>"` 的
    /// "No response requested."。API 报错（"Not logged in"、安全拦截）同样是 `<synthetic>`，
    /// 但带 `isApiErrorMessage`，那是用户该看到的，不算填充。
    /// 中断时它还会以 user 身份写一行 "[Request interrupted by user]"（没有任何标记），不能画成用户说的话；
    /// 中断本身看任务状态。
    static func isFiller(_ object: [String: Any]) -> Bool {
        if object["isMeta"] as? Bool == true { return true }
        if isInterruptionMarker(object) { return true }
        let message = object["message"] as? [String: Any]
        return message?["model"] as? String == "<synthetic>" && object["isApiErrorMessage"] as? Bool != true
    }

    /// 中断时以 user 身份写的那一行。
    static func isInterruptionMarker(_ object: [String: Any]) -> Bool {
        guard (object["type"] as? String) == "user",
              let text = plainText((object["message"] as? [String: Any])?["content"]) else { return false }
        return interruptionMarkers.contains(text.trimmed)
    }

    static let interruptionMarkers: Set<String> = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    ]

    /// 只由文字块组成的内容拼成一段；含图片、工具结果等其他块时是 nil。
    private static func plainText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]], !blocks.isEmpty,
              blocks.allSatisfy({ $0["type"] as? String == "text" }) else { return nil }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// transcript 一行里的 assistant 文本（含过程说明）；不是 assistant 或没有文字就是 nil。
    /// 两种常见形状：{type:"assistant", message:{content:[{type:"text",text:…}]}} 与扁平的 {role:…,content:…}
    static func assistantText(_ object: [String: Any]) -> String? {
        let role = (object["type"] as? String) ?? (object["role"] as? String)
        guard role == "assistant", !isFiller(object) else { return nil }
        let content = (object["message"] as? [String: Any])?["content"] ?? object["content"]
        if let text = content as? String, !text.trimmed.isEmpty { return text.trimmed }
        guard let blocks = content as? [[String: Any]] else { return nil }
        // 过程说明（narration 思考块）桌面上当正文显示，与对话记录一致也算。
        let text = blocks.compactMap { $0["text"] as? String ?? ClaudeMessageReader.narrationText($0) }
            .joined(separator: "\n").trimmed
        return text.isEmpty ? nil : text
    }

    // MARK: - 启动补历史

    /// 把 `~/.claude/projects` 里 7 天内的会话补进来（见 `ClaudeSessionHistory`）。
    ///
    /// 连接器每次启动调一次。扫描放在后台线程，期间 hook 照常进来；合并时 hook 已经建过的会话
    /// 以 hook 为准，只补它还不知道的标题与最后一条消息。补进来的是基线，不推通知。
    public func restoreRecentSessions() async {
        let directory = paths.projectsDirectory
        let current = now()
        let limit = Self.maxSessions
        let entries = await Task.detached(priority: .utility) {
            ClaudeSessionHistory.recentSessions(in: directory, now: current, limit: limit)
        }.value
        guard !entries.isEmpty else { return }
        for entry in entries { adopt(entry, now: current) }
        pruneIfNeeded()
        await publish(notify: false)
    }

    private func adopt(_ entry: ClaudeSessionHistory.Entry, now current: Date) {
        let startedAt = ProtocolJSON.timestamp(entry.startedAt)
        if let name = entry.model { noteModel(name) }
        let model = entry.model.flatMap { ClaudeModels.optionId(forTranscriptModel: $0) }
        if var session = sessions[entry.sessionID] {
            if let title = entry.title, entry.titleSource.replaces(session.titleSource) {
                session.title = title
                session.titleSource = entry.titleSource
            }
            if session.lastMessage == nil { session.lastMessage = entry.lastMessage }
            if session.model == nil { session.model = model }
            if startedAt < session.startedAt { session.startedAt = startedAt }
            sessions[entry.sessionID] = session
            return
        }
        var session = makeSession(id: entry.sessionID, projectPath: entry.projectPath, origin: .desktop)
        if let title = entry.title {
            session.title = title
            session.titleSource = entry.titleSource
        }
        // transcript 里看不出最后一轮是否正常结束；按 Stop 的映射记成已完成，超过 24 小时没动静按协议记 idle。
        session.status = current.timeIntervalSince(entry.updatedAt) > SessionFormatting.idleAfter ? .idle : .completed
        session.lastMessage = entry.lastMessage
        session.model = model
        session.startedAt = startedAt
        session.updatedAt = ProtocolJSON.timestamp(entry.updatedAt)
        sessions[entry.sessionID] = session
    }

    // MARK: - 会话状态

    /// 取出（或新建）一个会话，改完它，记下时间。Task 的产出统一在 `publish()`。
    private func apply(_ event: ClaudeHookEvent, _ mutate: (inout Session, ClaudeHookEvent) -> Void) {
        // 被分支取代的旧会话：桌面 hook 继续来，但手机上只该看到分支那一条。
        guard !superseded.contains(event.sessionID) else { return }
        let existing = sessions[event.sessionID]
        var session = existing ?? makeSession(id: event.sessionID, projectPath: event.cwd, origin: .desktop)
        if let path = event.transcriptPath, !path.isEmpty { session.transcriptPath = path }
        mutate(&session, event)
        let current = now()
        if session.isMidTurn, existing?.isMidTurn != true { session.turnStartedAt = current }
        session.updatedAt = ProtocolJSON.timestamp(current)
        sessions[event.sessionID] = session
        pruneIfNeeded()
        refreshAppTitle(after: event)
        scheduleTurnEndCheck()
    }

    // MARK: - 盯收尾标记

    /// 电脑上按停止（或在权限框里拒绝）只往 transcript 写一行 "[Request interrupted by user…]"，
    /// 不发 Stop，也没有别的 hook。所以电脑上的会话在跑时，每 `turnEndCheckInterval` 秒看一眼 transcript 末尾
    /// （只读 64 KB），见到这一轮的收尾标记就补上状态。没有要盯的会话时循环自己退出；这是 Claude 这边唯一的轮询。
    private func scheduleTurnEndCheck() {
        guard turnEndCheck == nil, !turnEndCandidates().isEmpty else { return }
        let interval = turnEndCheckInterval
        turnEndCheck = Task {
            while true {
                // 被 `stop()` 取消：那边已经清掉了句柄，这里别再动它。
                guard (try? await Task.sleep(for: .seconds(interval))) != nil else { return }
                guard await checkTurnEndings() else { break }
            }
            turnEndCheck = nil
        }
    }

    /// 要盯的会话：电脑上开的（我们自己的子进程由 `finish` 收尾）、正跑着、知道 transcript 在哪。
    private func turnEndCandidates() -> [(sessionID: String, path: String, since: Date?)] {
        sessions.values.compactMap { session in
            guard session.isMidTurn, let path = session.transcriptPath,
                  !isOwnTurn(session.sessionID) else { return nil }
            return (session.sessionID, path, session.turnStartedAt)
        }
    }

    /// 看一遍所有要盯的会话。返回 false = 没有要盯的了，循环退出。
    private func checkTurnEndings() async -> Bool {
        let candidates = turnEndCandidates()
        guard !candidates.isEmpty else { return false }
        let endings = await Task.detached(priority: .utility) {
            candidates.map { ClaudeSessionHistory.turnEnding(inTranscriptAt: $0.path) }
        }.value
        var changed = false
        for (candidate, ending) in zip(candidates, endings) {
            // 读文件时 actor 可能已经处理了新的 hook：会话还得是同一轮、仍在跑。
            guard let ending, let session = sessions[candidate.sessionID], session.isMidTurn,
                  session.turnStartedAt == candidate.since, !isOwnTurn(candidate.sessionID) else { continue }
            let endedAt: Date
            let status: TaskStatus
            switch ending {
            case .interrupted(let at): (endedAt, status) = (at, .interrupted)
            case .completed(let at): (endedAt, status) = (at, .completed)
            }
            if let since = candidate.since, endedAt < since.addingTimeInterval(-Self.turnEndSlack) { continue }
            releaseHold(for: session)
            var updated = session
            updated.status = status
            updated.pendingRequest = nil
            updated.updatedAt = ProtocolJSON.timestamp(now())
            sessions[candidate.sessionID] = updated
            changed = true
        }
        if changed { await publish() }
        return true
    }

    /// 测试用：立刻看一遍收尾标记，不等定时器。
    func checkTurnEndingsNow() async {
        _ = await checkTurnEndings()
    }

    /// 测试用：盯收尾标记的循环还在不在。
    var isCheckingTurnEndings: Bool { turnEndCheck != nil }

    // MARK: - 跟 app 起的标题

    /// 去 transcript 末尾取 Claude 起的标题。hook 路径上不碰文件：读取挪到后台，读到了再回 actor 改。
    /// 还没取到时按 `titleRetryDelays` 追几次；取到之后只在 Stop 时再看一眼，接住桌面 app 里的改名。
    private func refreshAppTitle(after event: ClaudeHookEvent) {
        guard let path = event.transcriptPath, !path.isEmpty,
              let session = sessions[event.sessionID], titleRefreshes[event.sessionID] == nil else { return }
        let delays: [TimeInterval]
        if session.titleSource < .generated {
            delays = titleRetryDelays
        } else if event.kind == .stop {
            delays = [0]
        } else {
            return
        }
        let sessionID = event.sessionID
        titleRefreshes[sessionID] = Task {
            for delay in delays {
                if delay > 0 { guard (try? await Task.sleep(for: .seconds(delay))) != nil else { break } }
                let found = await Task.detached(priority: .utility) {
                    ClaudeSessionHistory.appTitle(inTranscriptAt: path)
                }.value
                if let found {
                    await applyAppTitle(found.title, source: found.source, to: sessionID)
                    break
                }
            }
            titleRefreshes[sessionID] = nil
        }
    }

    private func applyAppTitle(_ title: String, source: TitleSource, to sessionID: String) async {
        guard var session = sessions[sessionID], source.replaces(session.titleSource),
              session.title != title || session.titleSource != source else { return }
        session.title = title
        session.titleSource = source
        sessions[sessionID] = session
        await publish()
    }

    /// 测试用：等进行中的标题刷新都跑完。
    func waitForTitleRefreshes() async {
        while let refresh = titleRefreshes.values.first { await refresh.value }
    }

    private func makeSession(id: String, projectPath: String, origin: TaskOrigin) -> Session {
        let timestamp = ProtocolJSON.timestamp(now())
        let name = Self.projectName(projectPath)
        return Session(sessionID: id,
                       projectPath: projectPath,
                       // 还没有 prompt，先用项目名占位（spec 6.3）。
                       title: name.isEmpty ? "Claude 会话" : name,
                       titleSource: .placeholder,
                       status: .running,
                       origin: origin,
                       startedAt: timestamp,
                       updatedAt: timestamp)
    }

    /// 手机新建会话时给 `claude --name` 的名字：和列表里的标题同一个来源（首条 prompt 截断），
    /// 控制字符与连续空白压成一个空格。名字写进 transcript 的 `custom-title`，终端的 `/resume` 列表、
    /// Claude 桌面 App 导入这条会话时都显示它；之后这里读回来是 `.named`，只有空白和标题不同。
    /// 只发图、没写字时不起名（标题是会被换掉的「图片」占位）。
    static func sessionName(for prompt: String) -> String? {
        // 控制字符（换行、制表、ESC……）一律当空白：名字之后会进终端标题，不能夹带转义序列。
        let visible = String(prompt.trimmed.prefix(titleLimit)).unicodeScalars
            .map { $0.properties.generalCategory == .control ? " " : String($0) }
            .joined()
        let name = visible.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// 手机新建（或分支出）的会话用 prompt 起标题。prompt 去掉空白后是空的：只发图时记「图片」，
    /// 否则留着 `makeSession` 的项目名占位——列表里这一行不能没有名字。
    static func applyPromptTitle(_ session: inout Session, prompt: String, hasImages: Bool) {
        let title = String(prompt.trimmed.prefix(titleLimit))
        if !title.isEmpty {
            session.title = title
            session.titleSource = .prompt
        } else if hasImages {
            session.title = imageOnlyTitle
            session.titleSource = .placeholder
        }
    }

    private func pruneIfNeeded() {
        guard sessions.count > Self.maxSessions else { return }
        let doomed = sessions.values
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(sessions.count - Self.maxSessions)
        for session in doomed {
            sessions.removeValue(forKey: session.sessionID)
            Task { [store, id = taskId(for: session.sessionID)] in await store.remove(id: id) }
        }
    }

    /// 把当前会话集合推进 TaskStore。
    ///
    /// 任务走 `claimLive` + `upsert`（本连接器是唯一权威），项目列表走 `reconcile` ——
    /// 协议里没有项目事件，只能靠它触发一份全量快照。`reconcile` 传空任务列表是安全的：
    /// 它只会删掉 observer 拥有的 id，而我们的都是 live。
    ///
    /// - Parameter notify: false = 静默写入，给启动补历史用——那是基线，不是变化。
    private func publish(notify: Bool = true) async {
        for session in sessions.values {
            await store.claimLive(taskId(for: session.sessionID))
            await store.upsert(record(session), notify: notify)
        }
        await store.reconcile(source: .claude, tasks: [], projects: projects())
        if modelsChanged {
            modelsChanged = false
            _ = await store.broadcastSnapshot()
        }
    }

    private func record(_ session: Session) -> TaskRecord {
        TaskRecord(id: taskId(for: session.sessionID),
                   agentId: "",
                   source: .claude,
                   title: session.title,
                   projectPath: session.projectPath,
                   projectName: Self.projectName(session.projectPath),
                   status: session.status,
                   lastMessage: session.lastMessage,
                   pendingRequest: session.pendingRequest,
                   origin: session.origin,
                   // Claude 的会话随时可以 `--resume` 接上，所以一律可控。
                   // 桌面上正在交互的会话会被分支而不是接管，这是已知取舍，在回执里说明。
                   controllable: true,
                   startedAt: session.startedAt,
                   updatedAt: session.updatedAt,
                   model: session.chosenModel ?? session.model,
                   effort: session.chosenEffort)
    }

    /// 见过的项目，按最近使用降序。`~/.claude/projects` 的目录名是把路径里的 `/` 换成 `-` 得到的，
    /// 反解不回来（路径里本来就可能有 `-`），所以只认会话自己报的 `cwd`。
    private func projects() -> [Project] {
        var latest: [String: String] = [:]
        for session in sessions.values where !session.projectPath.isEmpty {
            if let existing = latest[session.projectPath], existing >= session.updatedAt { continue }
            latest[session.projectPath] = session.updatedAt
        }
        return latest
            .sorted { $0.value > $1.value }
            .map { Project(agentId: "", path: $0.key, name: Self.projectName($0.key), lastUsedAt: $0.value, pinned: false) }
    }

    static func projectName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    // MARK: - TaskConnector

    public func start(projectPath: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        try await start(projectPath: projectPath, prompt: prompt, images: images, selection: ModelSelection())
    }

    /// 协议 3.2：第一次 `claude -p` 就带上手机选的 `--model` / `--effort`，并记到会话上，之后每次 `--resume` 沿用。
    public func start(projectPath: String, prompt: String, images: [URL],
                      selection: ModelSelection) async throws -> ConnectorOutcome {
        // 先查模型、再读图：不对就别起进程，也别签 token。
        let chosen = try Self.resolve(selection, current: nil, options: modelOptions ?? [])
        let input = try Self.streamingInput(prompt: prompt, images: images)
        let injection = await AgentToolsInjection.make(tools(), registry: registry)
        let executable = binary().map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let name = executable != nil && executable == binaryWithoutName ? nil : Self.sessionName(for: prompt)
        let launch = { (name: String?) in
            try await self.run(arguments: Self.arguments(prompt: prompt, resuming: nil, injection: injection,
                                                         streamingInput: input != nil,
                                                         model: chosen.model, effort: chosen.effort, name: name),
                               workingDirectory: projectPath, environment: injection?.environment ?? [:], stdin: input)
        }
        let sessionID: String
        do {
            sessionID = try await launch(name)
        } catch let error as ConnectorError where name != nil && error == Self.exitedWithoutSessionID {
            // 老版本 claude 不认 `--name`，一行 init 都没吐就退了（这时什么都还没做）：不带名字再起一次。
            // 别的原因（没登录……）早退的，第二次照样报同一个错。
            Self.log.info("claude 没吐 init 就退出了，去掉 --name 再起一次")
            sessionID = try await launch(nil)
            binaryWithoutName = executable
        }
        if let injection { await registry.bind(injection.token, taskId: taskId(for: sessionID)) }
        var session = makeSession(id: sessionID, projectPath: projectPath, origin: .watch)
        session.chosenModel = chosen.model
        session.chosenEffort = chosen.effort
        Self.applyPromptTitle(&session, prompt: prompt, hasImages: !images.isEmpty)
        sessions[sessionID] = session
        await publish()
        return ConnectorOutcome(taskId: sessionID, retainsLiveOwnership: true)
    }

    public func followUp(taskId: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        try await followUp(taskId: taskId, prompt: prompt, images: images, selection: ModelSelection())
    }

    /// 协议 3.2：先把手机选的模型与强度记到会话上，再照常续聊；之后的续聊都带着它们。
    /// 只收 `ClaudeModels` 里的别名与该模型支持的强度——值会变成 `claude` 的参数。
    /// 回答挂着的提问不另起一轮，换的模型从下一轮算起。
    public func followUp(taskId: String, prompt: String, images: [URL],
                         selection: ModelSelection) async throws -> ConnectorOutcome {
        let sessionID = try nativeID(taskId)
        var chosen = (model: sessions[sessionID]?.chosenModel, effort: sessions[sessionID]?.chosenEffort)
        if !selection.isEmpty {
            chosen = try Self.resolve(selection, current: sessions[sessionID], options: modelOptions ?? [])
            sessions[sessionID]?.chosenModel = chosen.model
            sessions[sessionID]?.chosenEffort = chosen.effort
        }
        // 会话正挂着 AskUserQuestion：这句话就是回答（和 Codex 的 requestUserInput 一样），不另起一轮。
        if let requestID = questionHolds.first(where: { $0.value.sessionID == sessionID })?.key {
            // 回答只收文字：带图就把图悄悄丢了，另起一轮又没人回提问。让用户先回答。
            guard images.isEmpty else { throw ConnectorError("Claude 正在等你回答问题，先回答再发图") }
            let text = prompt.trimmed
            if !text.isEmpty, let asked = questionHolds[requestID]?.asked,
               await answerQuestion(requestID, sessionID: sessionID,
                                        with: ClaudeHookOutput.answer(asked, answers: asked.claudeAnswers(text: text))) {
                return ConnectorOutcome(taskId: sessionID, retainsLiveOwnership: true)
            }
        }
        let input = try Self.streamingInput(prompt: prompt, images: images)
        let turn = QueuedTurn(prompt: prompt, input: input, hasImages: !images.isEmpty,
                              model: chosen.model, effort: chosen.effort)
        // 我们自己起的那一轮还没跑完：排队，等它结束再 `--resume`。同时起两个 `claude -p --resume`
        // 会把 transcript 分叉成两支，后一条看不到前一条的回答（手机在运行中也能发送）。
        if launching.contains(sessionID) || ownProcesses[sessionID]?.isRunning == true {
            queued[sessionID, default: []].append(turn)
            return ConnectorOutcome(taskId: sessionID, retainsLiveOwnership: true)
        }
        let newID = try await resume(sessionID, with: turn)
        await publish()
        return ConnectorOutcome(taskId: newID, retainsLiveOwnership: true)
    }

    /// 在已有会话上跑一轮 `claude -p --resume`，返回实际的 session id。
    private func resume(_ sessionID: String, with turn: QueuedTurn) async throws -> String {
        let existing = sessions[sessionID]
        let workingDirectory = existing?.projectPath ?? FileManager.default.currentDirectoryPath
        // `--resume` 对桌面上正在交互的会话会**分支**出一个新 session，而不是接进原会话。
        // 分支出来后旧 session 从列表里移除（`superseded`），手机上只看到分支那一条。
        // 续聊沿用这条任务之前的 token（agent 若把它记在了别处也照样有效）；分支出新 session 时改绑到新 id。
        launching.insert(sessionID)
        defer { launching.remove(sessionID) }
        let injection = await AgentToolsInjection.make(tools(), registry: registry, reusing: self.taskId(for: sessionID))
        let newID = try await run(arguments: Self.arguments(prompt: turn.prompt, resuming: sessionID, injection: injection,
                                                            streamingInput: turn.input != nil,
                                                            model: turn.model, effort: turn.effort),
                                  workingDirectory: workingDirectory, environment: injection?.environment ?? [:],
                                  stdin: turn.input)
        if let injection { await registry.bind(injection.token, taskId: self.taskId(for: newID)) }
        if newID != sessionID {
            var branched = makeSession(id: newID, projectPath: workingDirectory, origin: .watch)
            Self.applyPromptTitle(&branched, prompt: turn.prompt, hasImages: turn.hasImages)
            // 分支是同一段对话的延续：手机选的模型跟过去。
            branched.model = existing?.model
            branched.chosenModel = existing?.chosenModel
            branched.chosenEffort = existing?.chosenEffort
            sessions[newID] = branched
            // 旧会话被分支取代：从列表中移除，之后的桌面 hook 事件也不再接收。
            // 手机上只看到分支那一条，不会出现"一个会话变成两个"。
            if let old = sessions.removeValue(forKey: sessionID) { releaseHold(for: old) }
            superseded.insert(sessionID)
        } else {
            apply(ClaudeHookEvent.synthetic(kind: .userPromptSubmit, sessionID: sessionID, cwd: workingDirectory)) {
                session, _ in session.status = .running
            }
        }
        return newID
    }

    public func approve(taskId: String, requestId: String,
                        decision: Command.Approve.Decision) async throws -> ConnectorOutcome {
        try await approve(taskId: taskId, requestId: requestId, decision: decision, answers: nil)
    }

    public func approve(taskId: String, requestId: String, decision: Command.Approve.Decision,
                        answers: [String: [String]]?) async throws -> ConnectorOutcome {
        let sessionID = try nativeID(taskId)
        if let asked = questionHolds[requestId]?.asked {
            let reply: Data
            if decision == .deny {
                // 不回答不等于中断：Claude 收到这句话会接着往下做，任务仍在跑。
                reply = ClaudeHookOutput.permission(allow: false, reason: "用户在手机上跳过了这个问题")
            } else {
                let mapped = asked.claudeAnswers(answers ?? [:])
                guard !mapped.isEmpty else { throw ConnectorError("没有收到选项，请先选好再提交") }
                reply = ClaudeHookOutput.answer(asked, answers: mapped)
            }
            guard await answerQuestion(requestId, sessionID: sessionID, with: reply) else {
                // hook 已超时，Claude Code 回落到了电脑上的提问框。
                // 把选好的答案当续聊消息发过去：Claude 从历史里能看到问了什么。
                if decision != .deny {
                    let text = asked.claudeAnswers(answers ?? [:]).values.joined(separator: "\n")
                    if !text.isEmpty {
                        return try await followUp(taskId: taskId, prompt: text, images: [])
                    }
                }
                // 跳过的话没什么好发，把卡片收掉就行。
                if var session = sessions[sessionID], session.pendingRequest?.id == requestId {
                    session.pendingRequest = nil
                    sessions[sessionID] = session
                    await publish()
                }
                return ConnectorOutcome(taskId: sessionID, retainsLiveOwnership: true)
            }
            return ConnectorOutcome(taskId: sessionID, retainsLiveOwnership: true)
        }
        guard let hold = holds.removeValue(forKey: requestId) else {
            // 挂起的请求只活 120 秒，过了就没人收回答了；此时 Claude Code 已经回落到自己的弹窗。
            throw ConnectorError("这条审批已经过期，请在电脑上处理")
        }
        let allow = decision == .allow
        guard hold.answer(.json(ClaudeHookOutput.permission(allow: allow, reason: allow ? "已在手机上允许" : "已在手机上拒绝"))) else {
            // hold 对象还在字典里但已超时（清理任务还差零点几秒）：回答送不出去了。
            throw ConnectorError("这条审批已经过期，请在电脑上处理")
        }
        apply(ClaudeHookEvent.synthetic(kind: .userPromptSubmit, sessionID: sessionID,
                                        cwd: sessions[sessionID]?.projectPath ?? "")) { session, _ in
            session.pendingRequest = nil
            session.status = allow ? .running : .interrupted
        }
        await publish()
        return ConnectorOutcome(taskId: sessionID, retainsLiveOwnership: true)
    }

    /// 把回答交给挂着的 AskUserQuestion。已经超时（Claude Code 回落到电脑上的提问框）返回 false。
    private func answerQuestion(_ requestID: String, sessionID: String, with reply: Data) async -> Bool {
        questionHolds.removeValue(forKey: requestID)
        guard let hold = holds.removeValue(forKey: requestID), hold.answer(.json(reply)) else { return false }
        apply(ClaudeHookEvent.synthetic(kind: .userPromptSubmit, sessionID: sessionID,
                                        cwd: sessions[sessionID]?.projectPath ?? "")) { session, _ in
            if session.pendingRequest?.id == requestID { session.pendingRequest = nil }
            session.status = .running
        }
        await publish()
        return true
    }

    public func interrupt(taskId: String) async throws -> ConnectorOutcome {
        let sessionID = try nativeID(taskId)
        guard let process = ownProcesses[sessionID], process.isRunning else {
            // 桌面上用户自己开的会话不是我们的子进程，发不了信号。
            throw ConnectorError("这个会话是在电脑上启动的，只能在电脑上中断")
        }
        kill(process.processIdentifier, SIGINT)
        // 中断就是不要了：排在后面的续聊一并作废，不在这一轮退出后又自己跑起来。
        queued.removeValue(forKey: sessionID)
        apply(ClaudeHookEvent.synthetic(kind: .stop, sessionID: sessionID,
                                        cwd: sessions[sessionID]?.projectPath ?? "")) { session, _ in
            session.status = .interrupted
            session.pendingRequest = nil
        }
        await publish()
        return ConnectorOutcome(taskId: sessionID, retainsLiveOwnership: true)
    }

    private func nativeID(_ taskId: String) throws -> String {
        guard let colon = taskId.firstIndex(of: ":") else { return taskId }
        let native = String(taskId[taskId.index(after: colon)...])
        guard !native.isEmpty else { throw ConnectorError("任务 id 不合法：\(taskId)") }
        return native
    }

    /// 手机这次选的与会话上已经记着的合起来，得出之后每轮的 `--model` / `--effort`。
    /// 模型不认识、强度不在该模型的档位里都直接报错；换到不能调强度的模型（Haiku）时强度清掉。
    static func resolve(_ selection: ModelSelection, current session: Session?,
                        options: [ModelOption] = ClaudeModels.options) throws -> (model: String?, effort: String?) {
        if let model = selection.model, ClaudeModels.option(model, in: options) == nil {
            throw ConnectorError("Claude Code 没有「\(model)」这个模型")
        }
        let model = selection.model ?? session?.chosenModel
        let effective = ClaudeModels.option(model ?? session?.model, in: options)
        let allowed = effective.map { $0.efforts ?? [] } ?? (options.first?.efforts ?? [])
        if let effort = selection.effort, !allowed.contains(effort) {
            throw ConnectorError(allowed.isEmpty ? "这个模型不能调思考强度" : "Claude Code 没有「\(effort)」这档思考强度")
        }
        let effort = (selection.effort ?? session?.chosenEffort).flatMap { allowed.contains($0) ? $0 : nil }
        return (model, effort)
    }

    // MARK: - 子进程

    /// `claude` 的完整参数。顺序有讲究：`-p [--resume <id>] <prompt>` 在前；注入的
    /// `--mcp-config` / `--allowedTools` 是可变参数，只能排在 prompt 位置参数之后，
    /// 再由 `--output-format` 这个 `--flag` 收尾，否则 prompt 会被当成 MCP 配置文件或工具名吞掉。
    ///
    /// `streamingInput`（发图时）：prompt 连同图改走 stdin 的一行 stream-json（见 `stdinPayload`），
    /// 不再有位置参数；可变参数改由紧跟其后的 `--input-format` 收尾。不发图时参数与以前逐项相同。
    /// `model` / `effort`（协议 3.2）是 `--model` / `--effort`，排在 prompt 之前；值已由 `resolve` 限定在
    /// `ClaudeModels` 里，不会以 `-` 开头。`name`（只在新建时给，见 `sessionName`）也排在 prompt 之前，
    /// 写成一个 `--name=…`：名字来自用户的话，可能以 `-` 开头，分成两个参数会被当成别的选项。
    static func arguments(prompt: String, resuming sessionID: String?, injection: AgentToolsInjection?,
                          streamingInput: Bool = false, model: String? = nil, effort: String? = nil,
                          name: String? = nil) -> [String] {
        var arguments = ["-p"]
        if let sessionID { arguments += ["--resume", sessionID] }
        if let model { arguments += ["--model", model] }
        if let effort { arguments += ["--effort", effort] }
        if let name { arguments.append("--name=\(name)") }
        if !streamingInput { arguments.append(prompt) }
        if let injection { arguments += injection.claudeArguments() }
        if streamingInput { arguments += ["--input-format", "stream-json"] }
        arguments += ["--output-format", "stream-json", "--verbose"]
        return arguments
    }

    /// 发图时写进 stdin 的全部内容；不发图返回 nil（stdin 照旧继承，prompt 仍是位置参数）。
    /// 图在这里一次读进内存：读不到要在起进程之前就报错，而不是让 claude 收到半条消息。
    static func streamingInput(prompt: String, images: [URL]) throws -> Data? {
        guard !images.isEmpty else { return nil }
        let loaded = try images.map { url -> (data: Data, contentType: String) in
            guard let data = try? Data(contentsOf: url) else { throw ConnectorError("读不到要发送的图片") }
            return (data, mediaType(for: url))
        }
        return try stdinPayload(prompt: prompt, images: loaded)
    }

    /// `--input-format stream-json` 的一条用户消息：一行 JSON 加 `\n`，写完即关 stdin。
    /// 内容块是 Anthropic Messages 的形状：图在前（base64），文字在后；没有字就不放 text 块。
    static func stdinPayload(prompt: String, images: [(data: Data, contentType: String)]) throws -> Data {
        var content: [[String: Any]] = images.map {
            ["type": "image",
             "source": ["type": "base64", "media_type": $0.contentType, "data": $0.data.base64EncodedString()]]
        }
        if !prompt.trimmed.isEmpty { content.append(["type": "text", "text": prompt]) }
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        // 不带 `.prettyPrinted`，输出里不会有换行：整条消息就是一行。键排序让输出稳定可比；
        // 不转义 `/`：base64 里满是斜杠，转义会让几 MB 的数据平白再胀一截。
        var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// 由扩展名推 `media_type`。手机端发来的图都带扩展名；认不出的按 JPEG 报（手机默认转码成 JPEG）。
    static func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default: return "image/jpeg"
        }
    }

    /// 子进程环境：继承本进程，再叠上注入的变量（同名以注入为准）。
    ///
    /// 总是给出完整的一份：`Process.environment = nil` 在 macOS 26 上起出来的是**空**环境而不是继承，
    /// 没有 HOME 的 claude 读不到登录态，只会回 "Not logged in"。
    static func environment(adding extra: [String: String],
                            to base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.merging(extra) { _, injected in injected }
    }

    /// 起一个 `claude -p …` 并**只等到 session id 出现就返回**。
    ///
    /// 剩下的输出在后台接着读，用来把任务推进到结束——命令回执是"已接受"，不是"已完成"，
    /// 一轮可能跑几分钟，不能让客户端的请求挂在那里。
    ///
    /// `stdin` 非 nil（发图）时接一根管道，进程起来后在后台线程写完并关闭；nil 时照旧继承本进程的 stdin。
    private func run(arguments: [String], workingDirectory: String,
                     environment extra: [String: String] = [:], stdin: Data? = nil) async throws -> String {
        guard let executable = binary() else {
            throw ConnectorError("本机没找到 claude 可执行文件")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConnectorError("项目目录不存在：\(workingDirectory)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Self.environment(adding: extra)
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let input = stdin.map { _ in Pipe() }
        if let input { process.standardInput = input }

        let sessionID = OneShotContinuation<String>()
        let reader = StreamJSONReader(handle: output.fileHandleForReading)
        reader.onSessionID = { sessionID.resume(returning: $0) }
        reader.onFinished = { [weak self] result in
            Task { await self?.finish(result) }
        }
        process.terminationHandler = { _ in
            // 一行 init 都没吐出来就退了：别让调用方一直等到超时。
            sessionID.resume(throwing: Self.exitedWithoutSessionID)
            reader.finish()
        }

        do {
            try process.run()
        } catch {
            throw ConnectorError("起不了 claude：\(error.localizedDescription)")
        }
        reader.start()
        if let input, let stdin { Self.write(stdin, to: input.fileHandleForWriting) }

        let id = try await awaitSessionID(sessionID)
        ownProcesses[id] = process
        return id
    }

    /// 把整段 stdin 写进管道再关闭（关闭 = EOF，claude 才开始这一轮）。
    ///
    /// 几 MB 的 base64 远超管道缓冲，写入会阻塞到 claude 读走为止，所以放到后台线程，不占 actor；
    /// stdout 由 `StreamJSONReader` 独立读取，两头不会互相等死。管道关掉 SIGPIPE：claude 没读完就退出时
    /// 写入只是失败（进程退出那条路径会报错），不能把整个 app 带走。
    private static func write(_ data: Data, to handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    /// 等 session id，带硬超时。两条路径抢的是同一个 `OneShotContinuation`，
    /// 所以"超时了但 id 随后到了"不会二次 resume。
    private func awaitSessionID(_ box: OneShotContinuation<String>) async throws -> String {
        let timer = Task {
            try? await Task.sleep(for: .seconds(Self.sessionIDTimeout))
            box.resume(throwing: ConnectorError("等 claude 回应超时"))
        }
        defer { timer.cancel() }
        return try await box.value()
    }

    /// 后台读完一轮之后的收尾：写最终状态。
    private func finish(_ result: StreamJSONReader.Result) async {
        guard let sessionID = result.sessionID, sessions[sessionID] != nil else { return }
        ownProcesses.removeValue(forKey: sessionID)
        let next = queued[sessionID]?.first
        if next != nil { queued[sessionID]?.removeFirst() }
        if queued[sessionID]?.isEmpty == true { queued.removeValue(forKey: sessionID) }
        apply(ClaudeHookEvent.synthetic(kind: .stop, sessionID: sessionID,
                                        cwd: sessions[sessionID]?.projectPath ?? "")) { session, _ in
            // 已经被 interrupt 标过的不要被"进程退出"改回 completed。
            // 后面还排着续聊：保持 running，不在两轮之间推一条"任务完成"。
            if session.status != .interrupted, next == nil { session.status = result.failed ? .failed : .completed }
            session.pendingRequest = nil
            if let text = result.lastText?.trimmed, !text.isEmpty {
                session.lastMessage = String(text.prefix(Self.lastMessageLimit))
            }
        }
        if let next {
            do {
                let newID = try await resume(sessionID, with: next)
                // 分支出新 session 时，剩下的队列跟着新 id 走。
                if newID != sessionID, let rest = queued.removeValue(forKey: sessionID) { queued[newID] = rest }
            } catch {
                queued.removeValue(forKey: sessionID)
                apply(ClaudeHookEvent.synthetic(kind: .stop, sessionID: sessionID,
                                                cwd: sessions[sessionID]?.projectPath ?? "")) { session, _ in
                    session.status = .failed
                    session.lastMessage = String(error.localizedDescription.prefix(Self.lastMessageLimit))
                }
            }
        }
        await publish()
    }

}

private extension ClaudeHookEvent {
    /// 命令路径上用来复用 `apply(_:_:)` 的假事件：只带 id 与目录，其余字段留空。
    static func synthetic(kind: Kind, sessionID: String, cwd: String) -> ClaudeHookEvent {
        var object: [String: Any] = ["hook_event_name": kind.rawValue, "session_id": sessionID]
        if !cwd.isEmpty { object["cwd"] = cwd }
        // 这两个键保证能解析成功，强解不会爆。
        return ClaudeHookEvent(object: object)!
    }
}
