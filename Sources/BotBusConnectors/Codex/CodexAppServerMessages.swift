import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 线程在 app-server 眼里的状态（`thread/status/changed` 的 `status.type`）。
public enum CodexThreadStatus: Hashable, Sendable {
    case notLoaded
    case idle
    case active
    case systemError
    case unknown(String)

    init(_ raw: String) {
        switch raw {
        case "notLoaded": self = .notLoaded
        case "idle": self = .idle
        case "active": self = .active
        case "systemError": self = .systemError
        default: self = .unknown(raw)
        }
    }
}

/// 一个轮次的终态（`turn/completed` 的 `turn.status`）。
public enum CodexTurnStatus: Hashable, Sendable {
    case inProgress
    case completed
    case interrupted
    case failed
    case unknown(String)

    init(_ raw: String) {
        switch raw {
        case "inProgress": self = .inProgress
        case "completed": self = .completed
        case "interrupted": self = .interrupted
        case "failed": self = .failed
        default: self = .unknown(raw)
        }
    }
}

/// `fileChange` 条目里的一处改动。`item/fileChange/requestApproval` **不带**这些，
/// 它们只出现在同 itemId 的 `item/started` 里，所以 `CodexAppServer` 要缓存着等审批来配对。
public struct CodexFileChange: Hashable, Sendable {
    public var path: String
    /// `add` / `delete` / `update`（不同版本可能加新值，原样保留）。
    public var kind: String
    public var diff: String

    public init(path: String, kind: String, diff: String) {
        self.path = path
        self.kind = kind
        self.diff = diff
    }

    /// 从 `FileUpdateChange` 的 JSON 解出来。
    public init?(json value: JSONValue) {
        guard let path = value["path"]?.stringValue else { return nil }
        self.path = path
        self.kind = value["kind"]?.stringValue ?? "update"
        self.diff = value["diff"]?.stringValue ?? ""
    }
}

/// `item/started` / `item/completed` 携带的 ThreadItem。只挑用得上的字段，原始 JSON 留在 `raw` 里。
public struct CodexItem: Hashable, Sendable {
    public var id: String
    /// `agentMessage` / `commandExecution` / `fileChange` / …
    public var type: String
    /// `agentMessage.text`。
    public var text: String?
    /// `commandExecution.command`。
    public var command: String?
    /// `fileChange.changes`。
    public var changes: [CodexFileChange]
    public var raw: JSONValue

    /// 从 `ThreadItem` 的 JSON 解出来。
    public init?(json value: JSONValue) {
        guard let id = value["id"]?.stringValue, let type = value["type"]?.stringValue else { return nil }
        self.id = id
        self.type = type
        self.text = value["text"]?.stringValue
        self.command = value["command"]?.stringValue
        self.changes = (value["changes"]?.arrayValue ?? []).compactMap { CodexFileChange(json: $0) }
        self.raw = value
    }
}

/// 服务端通知。认得的解成具体 case，认不得的原样放进 `.other`——
/// app-server 每个版本都在加通知，认不得不该是错误。
public enum CodexNotification: Hashable, Sendable {
    case threadStarted(threadId: String, thread: JSONValue)
    case threadStatusChanged(threadId: String, status: CodexThreadStatus)
    case turnStarted(threadId: String, turnId: String)
    /// `errorInfo`：turn 错误里的 `codexErrorInfo`（单值变体是字符串，带字段的变体是只有一个键的对象，取键名）。
    case turnCompleted(threadId: String, turnId: String, status: CodexTurnStatus, error: String?, errorInfo: String?)
    case agentMessageDelta(threadId: String, itemId: String, delta: String)
    case itemStarted(threadId: String, turnId: String?, item: CodexItem)
    case itemCompleted(threadId: String, turnId: String?, item: CodexItem)
    case serverError(message: String)
    case other(method: String, params: JSONValue)

    /// 按方法名与 params 解成具体 case。认不得的落到 `.other`。
    public init(method: String, params: JSONValue) {
        switch method {
        case "thread/started":
            if let id = params.path("thread", "id")?.stringValue {
                self = .threadStarted(threadId: id, thread: params["thread"] ?? [:])
                return
            }
        case "thread/status/changed":
            if let id = params["threadId"]?.stringValue {
                let raw = params.path("status", "type")?.stringValue ?? ""
                self = .threadStatusChanged(threadId: id, status: CodexThreadStatus(raw))
                return
            }
        case "turn/started":
            if let id = params["threadId"]?.stringValue {
                self = .turnStarted(threadId: id, turnId: params.path("turn", "id")?.stringValue ?? "")
                return
            }
        case "turn/completed":
            if let id = params["threadId"]?.stringValue {
                let turn = params["turn"]
                let status = CodexTurnStatus(turn?["status"]?.stringValue ?? "")
                self = .turnCompleted(threadId: id, turnId: turn?["id"]?.stringValue ?? "",
                                      status: status, error: Self.errorText(turn?["error"]),
                                      errorInfo: Self.errorInfo(turn?["error"]))
                return
            }
        case "item/agentMessage/delta":
            if let id = params["threadId"]?.stringValue, let delta = params["delta"]?.stringValue {
                self = .agentMessageDelta(threadId: id, itemId: params["itemId"]?.stringValue ?? "", delta: delta)
                return
            }
        case "item/started":
            if let id = params["threadId"]?.stringValue, let item = params["item"].flatMap({ CodexItem(json: $0) }) {
                self = .itemStarted(threadId: id, turnId: params["turnId"]?.stringValue, item: item)
                return
            }
        case "item/completed":
            if let id = params["threadId"]?.stringValue, let item = params["item"].flatMap({ CodexItem(json: $0) }) {
                self = .itemCompleted(threadId: id, turnId: params["turnId"]?.stringValue, item: item)
                return
            }
        case "error":
            self = .serverError(message: params["message"]?.stringValue ?? "app-server 报错")
            return
        default:
            break
        }
        // 认得方法名但字段对不上（版本差异、畸形帧）时也走这里：宁可少理解一条，不要丢掉它。
        self = .other(method: method, params: params)
    }

    private static func errorText(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        if let text = value.stringValue { return text }
        return value["message"]?.stringValue
    }

    /// Codex app-server v2 的 `TurnError.codexErrorInfo`：`"usageLimitExceeded"`，或 `{"httpConnectionFailed": {...}}`。
    private static func errorInfo(_ value: JSONValue?) -> String? {
        guard let info = value?["codexErrorInfo"], !info.isNull else { return nil }
        if let text = info.stringValue { return text }
        if case .object(let fields) = info, fields.count == 1 { return fields.keys.first }
        return nil
    }

    public var method: String {
        switch self {
        case .threadStarted: return "thread/started"
        case .threadStatusChanged: return "thread/status/changed"
        case .turnStarted: return "turn/started"
        case .turnCompleted: return "turn/completed"
        case .agentMessageDelta: return "item/agentMessage/delta"
        case .itemStarted: return "item/started"
        case .itemCompleted: return "item/completed"
        case .serverError: return "error"
        case .other(let method, _): return method
        }
    }

    public var threadId: String? {
        switch self {
        case .threadStarted(let id, _): return id
        case .threadStatusChanged(let id, _): return id
        case .turnStarted(let id, _): return id
        case .turnCompleted(let id, _, _, _, _): return id
        case .agentMessageDelta(let id, _, _): return id
        case .itemStarted(let id, _, _): return id
        case .itemCompleted(let id, _, _): return id
        case .serverError: return nil
        case .other(_, let params): return params["threadId"]?.stringValue
        }
    }

    /// 这条通知意味着任务该变成什么状态；不代表状态变化的返回 nil。
    /// 映射见 spec 6.1：`turn/started` → running，`turn/completed` 看 payload，`thread/status/changed` 同步。
    ///
    /// 只做"协议语义 → 协议状态"的翻译，不碰 `TaskStore`：怎么用是连接器（Task 7）的事。
    public var statusTransition: TaskStatus? {
        switch self {
        case .turnStarted:
            return .running
        case .turnCompleted(_, _, let status, _, _):
            switch status {
            case .completed: return .completed
            case .failed: return .failed
            case .interrupted: return .interrupted
            case .inProgress: return .running
            case .unknown: return nil
            }
        case .threadStatusChanged(_, let status):
            switch status {
            case .active: return .running
            case .idle: return .idle
            case .systemError: return .failed
            case .notLoaded, .unknown: return nil
            }
        case .threadStarted, .agentMessageDelta, .itemStarted, .itemCompleted, .serverError, .other:
            return nil
        }
    }
}

/// 服务端主动发来的请求。**永远不会被 `CodexAppServer` 自动回复**——它只挂起来、往事件流里推一条，
/// 由 Task 7 的连接器决定变成 `PendingRequest` 还是回一条"不支持"。
public struct CodexServerRequest: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `item/commandExecution/requestApproval`
        case commandExecution
        /// `item/fileChange/requestApproval`
        case fileChange
        /// `item/permissions/requestApproval`
        case permissions
        /// `item/tool/requestUserInput`
        case userInput
        /// 其他服务端请求（`item/tool/call`、`mcpServer/elicitation/request`…）。同样不自动回。
        case other(String)

        init(method: String) {
            switch method {
            case "item/commandExecution/requestApproval": self = .commandExecution
            case "item/fileChange/requestApproval": self = .fileChange
            case "item/permissions/requestApproval": self = .permissions
            case "item/tool/requestUserInput": self = .userInput
            default: self = .other(method)
            }
        }

        /// 四类"要用户拿主意"的请求。其余的（刷新令牌、MCP elicitation）不属于审批。
        public var isApproval: Bool {
            switch self {
            case .commandExecution, .fileChange, .permissions: return true
            case .userInput, .other: return false
            }
        }

        /// 对应协议里的 `PendingRequest.kind`；不是审批也不是提问的返回 nil。
        public var pendingRequestKind: PendingRequest.Kind? {
            switch self {
            case .commandExecution: return .command
            case .fileChange: return .fileChange
            case .permissions: return .permission
            case .userInput: return .input
            case .other: return nil
            }
        }
    }

    /// 原样保留的 app-server 请求 id（字符串或整数），回复时必须用它。
    public var id: CodexRequestID
    public var method: String
    public var kind: Kind
    public var threadId: String?
    public var turnId: String?
    public var itemId: String?
    public var params: JSONValue
    /// 从同 itemId 的 `item/started` 缓存补来的补丁。审批请求自己不带 diff。
    public var fileChanges: [CodexFileChange]

    /// 挂起表的键，也是给 `PendingRequest.id` 用的字符串。
    public var key: String { id.key }

    public init(id: CodexRequestID, method: String, params: JSONValue,
                fileChanges: [CodexFileChange] = []) {
        self.id = id
        self.method = method
        self.kind = Kind(method: method)
        self.threadId = params["threadId"]?.stringValue
        self.turnId = params["turnId"]?.stringValue
        self.itemId = params["itemId"]?.stringValue
        self.params = params
        self.fileChanges = fileChanges
    }
}

/// `CodexAppServer` 往外推的一切。单订阅者（Task 7 的连接器）。
public enum CodexAppServerEvent: Sendable {
    /// 子进程起来了（`generation` 每起一次加一；第一次是 1）。握手还没完成。
    case started(generation: Int)
    /// 握手完成，可以发请求了。
    case ready(generation: Int)
    case notification(CodexNotification)
    /// 服务端请求到了，**没有**被回复。
    case serverRequest(CodexServerRequest)
    /// 子进程没了。`restartingIn` 非 nil 表示多少秒后自动重启；nil 表示不会重启（被 `stop()` 了）。
    case exited(CodexProcessExit, restartingIn: TimeInterval?)
    /// 重启后正在对这些之前由本机控制、且当时还在跑的线程逐个 `thread/resume`。
    case resumingAfterRestart(threadIds: [String])
}

/// 子进程的退出情况。`reason` 取 stderr 末尾的一小段，只用于界面提示，**不进日志**。
public struct CodexProcessExit: Hashable, Sendable {
    public var status: Int32
    public var reason: String?

    public init(status: Int32, reason: String? = nil) {
        self.status = status
        self.reason = reason
    }
}

/// `CodexAppServer` 抛出的一切。
public struct CodexAppServerError: LocalizedError, Hashable, Sendable, FailureDiagnosing {
    public enum Reason: Hashable, Sendable {
        /// 进程没起来、正在重启、或者已经 `stop()` 了。
        case notRunning
        /// 硬超时。
        case timedOut
        /// 等应答期间子进程退出了。
        case processExited
        /// 写 stdin 失败。
        case transport
        /// app-server 回了 JSON-RPC 错误。
        case server(code: Int)
        /// 要回复的服务端请求不在挂起表里（已被回答、已被丢弃，或者 key 是编的）。
        case unknownRequest
        /// 起子进程失败。
        case launchFailed
    }

    public var reason: Reason
    public var message: String
    /// 协议 3.7：连接器认出的失败原因。
    public var diagnosis: FailureDiagnosis?

    public init(_ reason: Reason, _ message: String) {
        self.reason = reason
        self.message = message
    }

    public var errorDescription: String? { message }

    static func notRunning(_ detail: String = "Codex app-server 还没就绪") -> Self { .init(.notRunning, detail) }
    static func timedOut(method: String, seconds: TimeInterval) -> Self {
        .init(.timedOut, "Codex \(method) 等了 \(Int(seconds)) 秒没有应答")
    }
    static func processExited(method: String) -> Self {
        .init(.processExited, "Codex app-server 在 \(method) 应答前退出了")
    }
}
