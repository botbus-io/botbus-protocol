import Foundation
import BotBusProtocol

/// 一条命令执行完之后，连接器对分发器的交代。
///
/// 比"返回 taskId"多出的那半句是 `retainsLiveOwnership`：命令返回不等于任务结束——
/// `approve` 之后轮次还要接着跑，`startTask` 之后 app-server 会一路推进度。这段时间里任务仍由实时数据
/// 驱动，只读观察（`CodexObserver`）无权改写，所以所有权不能跟着命令一起交还。
/// 连接器自己在任务真正结束时调 `TaskStore.releaseLive(_:)`。
public struct ConnectorOutcome: Hashable, Sendable {
    /// 受影响的任务 id。可以是协议里的完整 id（`codex:<threadId>`），也可以只给原生 id
    /// （`<threadId>`）——分发器会补上前缀。`followUp` 一般原样返回传入的 id；
    /// Claude 对桌面会话续聊会分支出新 session，此时返回新 id，分发器把它填进 `CommandResult.taskId`。
    public var taskId: String
    /// 命令返回后连接器是否仍在实时驱动这个任务。true 时分发器不交还所有权。
    public var retainsLiveOwnership: Bool

    public init(taskId: String, retainsLiveOwnership: Bool = false) {
        self.taskId = taskId
        self.retainsLiveOwnership = retainsLiveOwnership
    }
}

/// 连接器报错的通用载体。连接器也可以抛自己的错误类型：
/// 分发器会取 `LocalizedError.errorDescription`，没有就退回 `String(describing:)`，
/// 无论如何都会变成 `CommandResult{ok:false}`，不会有错误逃出分发器。
///
/// `containsPrivateDetail`：消息里带了不该进公开日志的内容（例如 ACP agent 进程退出时的 stderr 末尾、
/// 第三方 agent 自己回的错误文本）。它照样原样回给手机（`CommandResult.error`），分发器只是把它按
/// `privacy: .private` 记日志。
public struct ConnectorError: LocalizedError, Hashable, Sendable {
    public let message: String
    public let containsPrivateDetail: Bool

    public init(_ message: String, containsPrivateDetail: Bool = false) {
        self.message = message
        self.containsPrivateDetail = containsPrivateDetail
    }

    public var errorDescription: String? { message }
}

/// 一个能真正执行命令的后端（Codex app-server、Claude Code hooks + CLI）。
///
/// 两个实现互不知道对方：路由完全由 `CommandDispatcher` 按 `codex:` / `claude:` 前缀
/// （`startTask` 则按 `source` 字段）决定。方法都是 `async throws`，抛什么都会被分发器
/// 转成 `CommandResult{ok:false}`。
///
/// **返回时机**：这些方法应在"命令已被后端接受"时返回，而不是等任务跑完——命令可能跑几分钟，
/// 而 `CommandResult` 是给客户端的回执，不是完成通知。任务的进展靠 `TaskStore.upsert(_:)`
/// 产生的 `taskUpdated` 事件表达。
public protocol TaskConnector: Sendable {
    var kind: ConnectorKind { get }

    /// 新建任务。返回的 id 会被填进 `CommandResult.taskId`——客户端发 `startTask` 时还不知道 id，
    /// 只能从回执里认领。
    ///
    /// `images` 是手机随消息发来的图（协议 2.9），已由分发器下载到本机的文件 URL，按发送顺序排列。
    /// 目前只有 Codex 与 Claude 真的把图交给 agent；其余连接器收到非空的 `images` 直接报错，
    /// 而不是悄悄只发文字——用户会以为 agent 看过图了。
    func start(projectPath: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome

    /// 协议 3.2：新建任务时就指定模型与思考强度（`Command.StartTask.model` / `effort`），之后的续聊沿用。
    /// 和 `followUp(..., selection:)` 一样，只有报了 `ConnectorInfo.models` 的连接器需要实现，默认对非空的 `selection` 报错。
    func start(projectPath: String, prompt: String, images: [URL],
               selection: ModelSelection) async throws -> ConnectorOutcome

    /// 对已存在的任务续聊。Codex 若线程不在进程中要先 `thread/resume`。`images` 同 `start`。
    func followUp(taskId: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome

    /// 协议 3.2：续聊前换模型或思考强度（`Command.FollowUp.model` / `effort`），之后的续聊沿用。
    /// 只有报了 `ConnectorInfo.models` 的连接器（Codex、Claude）需要实现；默认对非空的 `selection` 报错——
    /// 悄悄用原模型跑，用户会以为已经换过了。
    func followUp(taskId: String, prompt: String, images: [URL],
                  selection: ModelSelection) async throws -> ConnectorOutcome

    /// 回复挂起的审批请求。`decision` 直接用协议的 `allow` / `deny`，
    /// 具体后端的决策值（Codex 的 `accept | acceptForSession | decline | cancel`）由连接器自己映射。
    func approve(taskId: String, requestId: String, decision: Command.Approve.Decision) async throws -> ConnectorOutcome

    /// 协议 2.14：带着 `PendingRequest.questions` 的回答批准。键是 `PendingQuestion.id`。
    /// 只有会出选项提问的连接器（Claude、Codex）需要实现；默认忽略 `answers`，走普通的 `approve`。
    func approve(taskId: String, requestId: String, decision: Command.Approve.Decision,
                 answers: [String: [String]]?) async throws -> ConnectorOutcome

    /// 中断当前轮次。
    func interrupt(taskId: String) async throws -> ConnectorOutcome
}

public extension TaskConnector {
    /// 不带图的旧签名：多数调用方（与测试）只发文字，不必每处都写 `images: []`。
    public func start(projectPath: String, prompt: String) async throws -> ConnectorOutcome {
        try await start(projectPath: projectPath, prompt: prompt, images: [])
    }

    public func followUp(taskId: String, prompt: String) async throws -> ConnectorOutcome {
        try await followUp(taskId: taskId, prompt: prompt, images: [])
    }

    public func approve(taskId: String, requestId: String, decision: Command.Approve.Decision,
                 answers: [String: [String]]?) async throws -> ConnectorOutcome {
        try await approve(taskId: taskId, requestId: requestId, decision: decision)
    }

    public func start(projectPath: String, prompt: String, images: [URL],
               selection: ModelSelection) async throws -> ConnectorOutcome {
        guard selection.isEmpty else { throw ConnectorError("这个 agent 不能从手机选模型") }
        return try await start(projectPath: projectPath, prompt: prompt, images: images)
    }

    public func followUp(taskId: String, prompt: String, images: [URL],
                  selection: ModelSelection) async throws -> ConnectorOutcome {
        guard selection.isEmpty else { throw ConnectorError("这个 agent 不能从手机换模型") }
        return try await followUp(taskId: taskId, prompt: prompt, images: images)
    }

    /// 把后端的原生 id（threadId / sessionId）拼成协议里的 `Task.id`。
    public func taskId(for native: String) -> String { "\(kind.rawValue):\(native)" }
}

public extension TaskSource {
    /// 从 `Task.id` 的前缀反解来源。`Task.id` 恒为 `<source>:<原生 id>`，两段都不能为空。
    public init?(taskId: String) {
        guard let colon = taskId.firstIndex(of: ":") else { return nil }
        guard let source = TaskSource(rawValue: String(taskId[taskId.startIndex..<colon])) else { return nil }
        guard taskId.index(after: colon) < taskId.endIndex else { return nil }
        self = source
    }
}

/// 协议 3.2：新建任务或续聊时要用的模型与思考强度。两样都是 nil = 不换（新建时 = agent 默认）。
public struct ModelSelection: Hashable, Sendable {
    public var model: String?
    public var effort: String?

    public init(model: String? = nil, effort: String? = nil) {
        self.model = model
        self.effort = effort
    }

    public init(_ payload: Command.FollowUp) {
        self.init(model: payload.model, effort: payload.effort)
    }

    public init(_ payload: Command.StartTask) {
        self.init(model: payload.model, effort: payload.effort)
    }

    public var isEmpty: Bool { model == nil && effort == nil }
}

/// 一个 kind 下挂着好几个 agent 的连接器（目前只有 ACP，协议 2.13）：新建任务要多给一个 connectorId。
/// 续聊、审批、中断不需要——任务 id 里已经带着它（`acp:<connectorId>:<sessionId>`）。
public protocol MultiAgentConnector: TaskConnector {
    /// 这个 agent 此刻能不能接命令（在、没被藏起来、没停用），不能就抛出说明。分发器在下载图片、
    /// 建新项目文件夹之前先问它：不然 agent 不可用时会白留一个空目录，重试还会报"已经存在"。
    func checkAvailable(connectorId: String) async throws

    func start(connectorId: String, projectPath: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome
}
