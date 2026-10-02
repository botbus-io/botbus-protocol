import Foundation
import BotBusProtocol
import BotBusConnectorKit

// DeepSeek Harness（dsh 0.1.5-rc.3）会话日志与 `dsh web` 内部接口的消息形状。都是 dsh 的内部格式，
// 升级可能改；解析一律宽松：缺必需字段的整条当"不认识"（返回 nil 或 `.other`），不抛错。
// 时间在 dsh 里都是毫秒整数。

/// 毫秒时间戳 → Date。
func dshDate(_ value: JSONValue?) -> Date? {
    guard let ms = value?.doubleValue else { return nil }
    return Date(timeIntervalSince1970: ms / 1000)
}

/// 会话头：JSONL 首行（`{type:"session", …}`）或 follow 流 snapshot 的 `header`（不带 `type`）。
public struct DshSessionHeader: Hashable, Sendable {
    public var id: String
    public var createdAt: Date?
    public var cwd: String?
    /// 直接上级会话：subagent 与 fork 出来的会话都有。
    public var parentSession: String?
    /// `"subagent"` = 子 agent 的会话（与父会话同目录）；fork 没有这个字段。
    public var origin: String?
    public var delegationDepth: Int
    public var isSeeded: Bool

    public init(id: String, createdAt: Date? = nil, cwd: String? = nil, parentSession: String? = nil,
                origin: String? = nil, delegationDepth: Int = 0, isSeeded: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.cwd = cwd
        self.parentSession = parentSession
        self.origin = origin
        self.delegationDepth = delegationDepth
        self.isSeeded = isSeeded
    }

    /// `type` 有就必须是 `session`；`id` 必须非空。
    public init?(json: JSONValue) {
        if let type = json["type"]?.stringValue, type != "session" { return nil }
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.init(id: id, createdAt: dshDate(json["createdAt"]),
                  cwd: json["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                  parentSession: json["parentSession"]?.stringValue, origin: json["origin"]?.stringValue,
                  delegationDepth: Int(json["delegationDepth"]?.intValue ?? 0), isSeeded: json["isSeeded"]?.boolValue ?? false)
    }

    /// 子 agent 的会话：不当任务列出来。只看 `origin` 与委派深度，fork（有 `parentSession`、没有 `origin`）照常列。
    public var isSubagent: Bool { origin == "subagent" || delegationDepth > 0 }
}

/// 会话日志里的一个事件 `{type, seq, time, data}`。JSONL 的行与 web 的 follow 流（`{type:"event", event:{…}}`）都解成它。
public struct DshSessionEvent: Hashable, Sendable {
    public var type: String
    public var seq: Int64
    public var time: Date?
    public var data: JSONValue
    /// 进模型上下文的方式：`"append"`，或压缩上下文时的替换 `{op:"replace", startSeq, endSeq}`；非消息事件没有。
    public var surfaceOp: JSONValue?

    public init(type: String, seq: Int64, time: Date?, data: JSONValue, surfaceOp: JSONValue? = nil) {
        self.type = type
        self.seq = seq
        self.time = time
        self.data = data
        self.surfaceOp = surfaceOp
    }

    /// 裸事件（JSONL 一行）或 `{type:"event", event:{…}}` 包着的都认；头行、别的记录返回 nil。
    public init?(json: JSONValue) {
        var body = json
        if json["type"]?.stringValue == "event", let inner = json["event"], inner.objectValue != nil { body = inner }
        guard let type = body["type"]?.stringValue, type != "session", type != "event",
              let seq = body["seq"]?.intValue else { return nil }
        self.init(type: type, seq: seq, time: dshDate(body["time"]), data: body["data"] ?? .null, surfaceOp: body["surfaceOp"])
    }

    /// `user/message` 的来源：`user` 才是人发的提示词（ACP 的不带 `rpcId`，web 的带）；
    /// 运行时上下文是 `plugin`，技能目录是 `skill-catalog`。
    public var sourceKind: String? { data.path("source", "kind")?.stringValue }

    /// `user/message` 的文字（`content` 里 `text` 段拼起来）；`assistant/message` 的回复文字（`message.content` 的 `text` 段，
    /// 不含 `reasoning` 与 `tool-call`）。别的事件为 nil。
    public var text: String? {
        switch type {
        case "user/message":
            return Self.texts(data["content"]).map {
                DshToolsContext.visibleText($0, requestId: data.path("source", "rpcId")?.stringValue)
            }
        case "assistant/message": return Self.texts(data.path("message", "content"))
        default: return nil
        }
    }

    static func texts(_ content: JSONValue?) -> String? {
        guard let blocks = content?.arrayValue else { return nil }
        return blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
    }

    /// `session/title` 的标题。
    public var title: String? { type == "session/title" ? data["title"]?.stringValue : nil }

    /// `turn/end` 的结束原因。
    public var turnEndReason: DshTurnEndReason? {
        guard type == "turn/end" else { return nil }
        return DshTurnEndReason(json: data["reason"] ?? .null)
    }
}

/// `turn/end.reason.kind`：`completed | aborted | interrupted | error | blocked | max-tokens`。
public enum DshTurnEndReason: Hashable, Sendable {
    case completed
    case aborted
    case interrupted
    /// 带 dsh 给的错误文本（模型报错等）：可能含请求细节，只给界面，不进公开日志。
    case error(message: String?)
    case blocked
    case maxTokens
    case other(String)

    public init(json: JSONValue) {
        switch json["kind"]?.stringValue ?? "" {
        case "completed": self = .completed
        case "aborted": self = .aborted
        case "interrupted": self = .interrupted
        case "error": self = .error(message: json.path("error", "message")?.stringValue)
        case "blocked": self = .blocked
        case "max-tokens": self = .maxTokens
        case let kind: self = .other(kind)
        }
    }

    /// completed → completed；aborted / interrupted → interrupted；error / blocked / max-tokens 与认不出的 → failed。
    public var status: TaskStatus {
        switch self {
        case .completed: .completed
        case .aborted, .interrupted: .interrupted
        case .error, .blocked, .maxTokens, .other: .failed
        }
    }
}

/// `session/list` 的一项，也是 `$events` 里 `api-session/added` 的参数。
public struct DshWebSessionSummary: Hashable, Sendable {
    public var sessionId: String
    /// web 算的是 `max(createdAt, lastPromptAt)`，不是文件修改时间。
    public var updatedAt: Date?
    public var running: Bool
    /// 从没开过一轮（`turn/start`）的空会话。
    public var blank: Bool
    public var cwd: String?
    public var parentSessionId: String?
    public var origin: String?
    public var title: String?
    /// 投影缓存算到的那条事件的 seq（`projections.asOfSeq`）。**可能过时**（ACP 进程写的缓存常停在会话开头），
    /// 不能拿来当 `session/page` 的游标，用 `DshWebClient.latestPage`。
    public var asOfSeq: Int64?

    public init(sessionId: String, updatedAt: Date?, running: Bool, blank: Bool, cwd: String?,
                parentSessionId: String? = nil, origin: String? = nil, title: String? = nil, asOfSeq: Int64? = nil) {
        self.sessionId = sessionId
        self.updatedAt = updatedAt
        self.running = running
        self.blank = blank
        self.cwd = cwd
        self.parentSessionId = parentSessionId
        self.origin = origin
        self.title = title
        self.asOfSeq = asOfSeq
    }

    public init?(json: JSONValue) {
        guard let id = json["sessionId"]?.stringValue, !id.isEmpty else { return nil }
        self.init(sessionId: id, updatedAt: dshDate(json["updatedAt"]), running: json["running"]?.boolValue ?? false,
                  blank: json["blank"]?.boolValue ?? false,
                  cwd: json["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                  parentSessionId: json["parentSessionId"]?.stringValue, origin: json["origin"]?.stringValue,
                  title: json.path("projections", "values", "title")?.stringValue,
                  asOfSeq: json.path("projections", "asOfSeq")?.intValue)
    }

    public var isSubagent: Bool { origin == "subagent" }
}

/// `$events` 流里的一项（`item.value`）。
public enum DshEventsFrame: Hashable, Sendable {
    /// 首条：`clientId` 用来回 `$events/result`；`home` 是 dsh 所在账户的主目录。
    case ready(clientId: String, home: String?)
    case emit(DshSessionEmit)
    /// 审批 / 提问，发给所有已连的客户端，先答者生效。
    case waterfall(DshWaterfall)
    /// 这条 waterfall 已被别处答掉（或取消）。
    case cancel(eventId: String)
    case other(String)

    public init(json: JSONValue) {
        switch json["type"]?.stringValue ?? "" {
        case "ready":
            guard let clientId = json["clientId"]?.stringValue, !clientId.isEmpty else { self = .other("ready"); return }
            self = .ready(clientId: clientId, home: json.path("host", "home")?.stringValue)
        case "emit":
            self = .emit(DshSessionEmit(event: json["event"]?.stringValue ?? "", args: json["args"]?.arrayValue ?? []))
        case "waterfall":
            self = DshWaterfall(json: json).map(Self.waterfall) ?? .other("waterfall")
        case "cancel":
            guard let eventId = json["eventId"]?.stringValue else { self = .other("cancel"); return }
            self = .cancel(eventId: eventId)
        case let type:
            self = .other(type)
        }
    }
}

/// `$events` 的 `emit`。只认会话相关的五种，别的（设置变了等）放 `.other`。
public enum DshSessionEmit: Hashable, Sendable {
    case added(DshWebSessionSummary)
    case removed(sessionId: String)
    case status(sessionId: String, running: Bool)
    case activity(sessionId: String, at: Date?)
    /// dsh 给的错误文本，只给界面。
    case error(sessionId: String, message: String?)
    case other(event: String)

    public init(event: String, args: [JSONValue]) {
        let sessionId = args.first?.stringValue
        switch event {
        case "api-session/added":
            self = args.first.flatMap(DshWebSessionSummary.init(json:)).map(Self.added) ?? .other(event: event)
        case "api-session/removed":
            self = sessionId.map { .removed(sessionId: $0) } ?? .other(event: event)
        case "api-session/status":
            guard let sessionId, let running = args.dropFirst().first?.boolValue else { self = .other(event: event); return }
            self = .status(sessionId: sessionId, running: running)
        case "api-session/activity":
            self = sessionId.map { .activity(sessionId: $0, at: dshDate(args.dropFirst().first)) } ?? .other(event: event)
        case "api-session/error":
            self = sessionId.map { .error(sessionId: $0, message: args.dropFirst().first?.stringValue) } ?? .other(event: event)
        default:
            self = .other(event: event)
        }
    }
}

/// 一条 waterfall：`approval/request` 或 `user-questions/request`。`agentId` 就是会话 id。
public struct DshWaterfall: Hashable, Sendable {
    public enum Request: Hashable, Sendable {
        /// 审批：回 `"allowed-once"` 或 `"rejected"`（见 `DshWebClient.answerApproval`）。
        case approval(toolName: String?, callId: String?, reason: String?)
        /// 提问：回 `{answers:[{id, selected:[label]}]}`。
        case questions([DshQuestion])
        case other(event: String)
    }

    public var eventId: String
    public var sessionId: String
    public var request: Request

    public init(eventId: String, sessionId: String, request: Request) {
        self.eventId = eventId
        self.sessionId = sessionId
        self.request = request
    }

    public init?(json: JSONValue) {
        guard let eventId = json["eventId"]?.stringValue, !eventId.isEmpty,
              let sessionId = json["agentId"]?.stringValue, !sessionId.isEmpty else { return nil }
        let request = json["request"] ?? .null
        let event = json["event"]?.stringValue ?? ""
        switch event {
        case "approval/request":
            self.init(eventId: eventId, sessionId: sessionId, request: .approval(
                toolName: request["toolName"]?.stringValue, callId: request["callId"]?.stringValue,
                reason: request["reason"]?.stringValue))
        case "user-questions/request":
            self.init(eventId: eventId, sessionId: sessionId,
                      request: .questions(request["questions"]?.arrayValue?.compactMap(DshQuestion.init(json:)) ?? []))
        default:
            self.init(eventId: eventId, sessionId: sessionId, request: .other(event: event))
        }
    }
}

/// `ask_user_question` 的一道题。
public struct DshQuestion: Hashable, Sendable {
    public var id: String
    public var question: String
    public var header: String?
    public var detail: String?
    public var options: [String]
    public var multiSelect: Bool

    public init(id: String, question: String, header: String? = nil, detail: String? = nil, options: [String],
                multiSelect: Bool = false) {
        self.id = id
        self.question = question
        self.header = header
        self.detail = detail
        self.options = options
        self.multiSelect = multiSelect
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.init(id: id, question: json["question"]?.stringValue ?? "", header: json["header"]?.stringValue,
                  detail: json["detail"]?.stringValue,
                  options: json["options"]?.arrayValue?.compactMap { $0["label"]?.stringValue } ?? [],
                  multiSelect: json["multiSelect"]?.boolValue ?? false)
    }
}

/// `session/follow` 流里的一项。
public enum DshFollowFrame: Hashable, Sendable {
    /// 首帧：会话头、游标、最近的记录（`records` 里认得出的事件；别的记录丢掉）、前面还有没有更早的。
    case snapshot(header: DshSessionHeader?, cursor: Int64?, events: [DshSessionEvent], hasMore: Bool)
    case event(DshSessionEvent)
    case other(String)

    public init(json: JSONValue) {
        switch json["type"]?.stringValue ?? "" {
        case "snapshot":
            self = .snapshot(header: json["header"].flatMap(DshSessionHeader.init(json:)), cursor: json["cursor"]?.intValue,
                             events: json["records"]?.arrayValue?.compactMap(DshSessionEvent.init(json:)) ?? [],
                             hasMore: json["hasMore"]?.boolValue ?? false)
        case "event":
            self = DshSessionEvent(json: json).map(Self.event) ?? .other("event")
        case let type:
            self = .other(type)
        }
    }
}
