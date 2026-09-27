import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// ACP（Agent Client Protocol）里 BotBus 用到的那一小部分。字段名以官方 schema 为准（落地前逐项核对过），
/// 解析一律宽松：认不出的字段跳过，缺必需字段的整条当"不认识"，一条坏消息不能让整个会话停摆。
public enum AcpProtocol {
    /// 我们实现的 ACP 协议版本（`initialize.protocolVersion`）。
    public static let version: Int64 = 1
    /// `auth_required` 的错误码。
    public static let authRequiredCode = -32000
    /// 反向扩展专用：BotBus 对这条审批没有答案（不归这条连接、被新请求顶掉、这一轮已结束）。
    /// agent 收到它应当继续等终端里的回答，而不是当成用户取消（spec「反向扩展」）。
    public static let noAnswerCode = -32001
}

/// `AcpConnector` 抛出的、调用方要按类别处理的错误（其余一律是 `ConnectorError`）。
/// `message` 是给手机看的中文，不含会话内容，可以公开进日志。
public struct AcpConnectorError: LocalizedError, Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// `session/resume` 撞上会话锁：这个会话正被电脑上别的进程写着（DeepSeek Harness 的 web 载入过的会话一直持锁）。
        /// 一档的 DshConnector 据此改走 web 通道。
        case sessionBusyElsewhere
        /// 内存里没有这个会话的对话记录，agent 又不能 `session/load`：调用方该用自己的读取器（读盘、问 web）。
        case transcriptUnavailable
    }

    public let reason: Reason
    public let message: String

    public init(_ reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }

    public var errorDescription: String? { message }

    /// dsh 的会话锁错误：-32603，`data.details`（或 message）里有 `already owned by an active write handle`。
    static func isSessionLockError(_ error: JSONRPCError) -> Bool {
        guard error.code == JSONRPCError.internalError else { return false }
        let marker = "already owned by an active write handle"
        let details = error.data?["details"]?.stringValue ?? error.data?.stringValue ?? ""
        return details.contains(marker) || error.message.contains(marker)
    }
}

public enum AcpStopReason: String, Hashable, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}

/// `initialize` 协商出的能力。
public struct AcpCapabilities: Hashable, Sendable {
    public var protocolVersion: Int64
    /// 能 `session/load`：续聊不在当前进程里的会话、读历史都靠它。
    public var loadSession: Bool
    /// prompt 里能放图。
    public var images: Bool
    /// 能 `session/list`（ACP v1 稳定 schema 里的可选能力 `sessionCapabilities.list`）。
    public var listSessions: Bool
    /// 能 `session/resume`（`sessionCapabilities.resume`）：接上不在当前进程里的会话继续聊，但**不重放历史**。
    /// 没有 `loadSession` 时续聊靠它；读历史不能靠它（见 `AcpConnector.entries`）。
    public var resumeSession: Bool
    /// `authMethods` 的个数：非 0 说明这个 agent 可能要求先登录。
    public var authMethodCount: Int

    public init(protocolVersion: Int64 = AcpProtocol.version, loadSession: Bool = false, images: Bool = false,
                listSessions: Bool = false, resumeSession: Bool = false, authMethodCount: Int = 0) {
        self.protocolVersion = protocolVersion
        self.loadSession = loadSession
        self.images = images
        self.listSessions = listSessions
        self.resumeSession = resumeSession
        self.authMethodCount = authMethodCount
    }

    /// 续聊不在当前进程里的会话有没有办法（载入或接上）。
    public var canContinueSessions: Bool { loadSession || resumeSession }

    public init(initializeResult result: JSONValue) {
        let agent = result["agentCapabilities"]
        self.init(protocolVersion: result["protocolVersion"]?.intValue ?? 0,
                  loadSession: agent?["loadSession"]?.boolValue ?? false,
                  images: agent?.path("promptCapabilities", "image")?.boolValue ?? false,
                  // `sessionCapabilities.list` 在（通常是个空对象）就算支持。
                  listSessions: agent?.path("sessionCapabilities", "list").map { !$0.isNull } ?? false,
                  resumeSession: agent?.path("sessionCapabilities", "resume").map { !$0.isNull } ?? false,
                  authMethodCount: result["authMethods"]?.arrayValue?.count ?? 0)
    }
}

/// 一次工具调用（`tool_call` / `tool_call_update` / 审批请求里的 `toolCall`）。
public struct AcpToolCall: Hashable, Sendable {
    public var toolCallId: String
    public var title: String?
    /// `read | edit | delete | move | search | execute | think | fetch | switch_mode | other`
    public var kind: String?
    /// `pending | in_progress | completed | failed`
    public var status: String?
    /// `rawInput`：这条工具调用真正的原始参数（比如要执行的命令）。跟 `contentText` 分开存，
    /// 是因为同一个 `toolCallId` 后续的 `tool_call_update`（含审批请求里的 `toolCall`）常常只带
    /// 一句面向人的说明文字（`content` 里的文本），没有 `rawInput`——合并时不能让这句话把原始命令
    /// 顶掉，否则手机上的审批卡片就看不到真正要跑的命令了。
    var rawInput: String?
    /// 没有 `rawInput` 时从 `content` 里拼出来的文本（比如工具执行完的输出、一段说明）。
    var contentText: String?

    /// 给手机看的细节：优先原始输入，没有才退到内容文本。
    public var detail: String? { rawInput ?? contentText }

    public init?(json: JSONValue) {
        guard let id = json["toolCallId"]?.stringValue, !id.isEmpty else { return nil }
        toolCallId = id
        title = json["title"]?.stringValue
        kind = json["kind"]?.stringValue
        status = json["status"]?.stringValue
        if let raw = json["rawInput"], !raw.isNull {
            rawInput = raw.stringValue ?? (try? raw.acpLineOrThrow())
        }
        let texts = json["content"]?.arrayValue?.compactMap {
            $0.path("content", "text")?.stringValue ?? $0["text"]?.stringValue
        } ?? []
        contentText = texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// 合并一条 `tool_call_update`：它只带变了的字段，`rawInput` 与 `contentText` 各自独立合并——
    /// 一条只有说明文字、没有 `rawInput` 的更新不能覆盖掉之前记住的原始命令。
    public func merging(_ update: AcpToolCall) -> AcpToolCall {
        var merged = self
        merged.title = update.title ?? title
        merged.kind = update.kind ?? kind
        merged.status = update.status ?? status
        merged.rawInput = update.rawInput ?? rawInput
        merged.contentText = update.contentText ?? contentText
        return merged
    }

    /// 协议里的 `PendingRequest.kind`。
    public var pendingKind: PendingRequest.Kind {
        switch kind {
        case "execute": .command
        case "edit", "delete", "move": .fileChange
        default: .permission
        }
    }
}

public struct AcpImage: Hashable, Sendable {
    public var base64: String
    public var mimeType: String

    public init(base64: String, mimeType: String) {
        self.base64 = base64
        self.mimeType = mimeType
    }
}

/// `session/update` 里 BotBus 关心的几种。
public enum AcpSessionUpdate: Hashable, Sendable {
    case userMessage(text: String, images: [AcpImage])
    case agentMessage(text: String, images: [AcpImage])
    case thought
    case toolCall(AcpToolCall)
    case toolCallUpdate(AcpToolCall)
    case sessionInfo(title: String?)
    case other(String)

    public init(json update: JSONValue) {
        let kind = update["sessionUpdate"]?.stringValue ?? ""
        switch kind {
        case "user_message_chunk":
            let (text, images) = Self.content(update["content"] ?? .null)
            self = .userMessage(text: text, images: images)
        case "agent_message_chunk":
            let (text, images) = Self.content(update["content"] ?? .null)
            self = .agentMessage(text: text, images: images)
        case "agent_thought_chunk":
            self = .thought
        case "tool_call":
            self = AcpToolCall(json: update).map(Self.toolCall) ?? .other(kind)
        case "tool_call_update":
            self = AcpToolCall(json: update).map(Self.toolCallUpdate) ?? .other(kind)
        case "session_info_update":
            self = .sessionInfo(title: update["title"]?.stringValue)
        default:
            self = .other(kind)
        }
    }

    static func content(_ block: JSONValue) -> (String, [AcpImage]) {
        switch block["type"]?.stringValue {
        case "text":
            return (block["text"]?.stringValue ?? "", [])
        case "image":
            guard let data = block["data"]?.stringValue, let mime = block["mimeType"]?.stringValue else { return ("", []) }
            return ("", [AcpImage(base64: data, mimeType: mime)])
        default:
            return ("", [])
        }
    }
}

public struct AcpPermissionOption: Hashable, Sendable {
    public var optionId: String
    public var name: String
    /// `allow_once | allow_always | reject_once | reject_always`
    public var kind: String

    public init?(json: JSONValue) {
        guard let id = json["optionId"]?.stringValue, let kind = json["kind"]?.stringValue else { return nil }
        optionId = id
        name = json["name"]?.stringValue ?? id
        self.kind = kind
    }
}

/// agent 发来的 `session/request_permission`。
public struct AcpPermissionRequest: Hashable, Sendable {
    public var sessionId: String
    public var toolCall: AcpToolCall
    public var options: [AcpPermissionOption]

    public init?(params: JSONValue) {
        guard let sessionId = params["sessionId"]?.stringValue,
              let toolCall = params["toolCall"].flatMap(AcpToolCall.init(json:)) else { return nil }
        self.sessionId = sessionId
        self.toolCall = toolCall
        options = params["options"]?.arrayValue?.compactMap(AcpPermissionOption.init(json:)) ?? []
    }

    /// 手机上的允许 / 拒绝挑哪个选项。先挑"一次性"的，没有才退到"总是"——手机上点一下不该悄悄变成永久授权。
    public func optionId(for decision: Command.Approve.Decision) -> String? {
        let order = decision == .allow ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        for kind in order {
            if let hit = options.first(where: { $0.kind == kind }) { return hit.optionId }
        }
        return nil
    }

    /// 协议 2.14：审批上的「允许范围」。`allow_*` 选项按 once 在前、always 在后列成一道单选，
    /// 第一个就是 `optionId(for: .allow)` 会挑的那个——手机默认选它，旧手机不带 `answers` 效果不变。
    /// 拒绝类选项不列（那是「拒绝」按钮）。同名的只留第一个：手机回的是 `label`。
    public static let scopeQuestionId = "scope"
    public var allowOptions: [AcpPermissionOption] {
        var seen: Set<String> = []
        return ["allow_once", "allow_always"].flatMap { kind in options.filter { $0.kind == kind } }
            .filter { seen.insert($0.name).inserted }
    }

    public var pendingQuestions: [PendingQuestion]? {
        let allow = allowOptions
        guard !allow.isEmpty else { return nil }
        return [PendingQuestion(id: Self.scopeQuestionId, question: "允许范围",
                                options: allow.map { PendingOption(label: $0.name) })]
    }

    /// 手机选中的范围 → `optionId`。对不上、没带、多选都回落到 `optionId(for: .allow)`；拒绝不看 `answers`。
    public func optionId(for decision: Command.Approve.Decision, answers: [String: [String]]?) -> String? {
        if decision == .allow, let picked = answers?[Self.scopeQuestionId], picked.count == 1,
           let hit = allowOptions.first(where: { $0.name == picked[0] }) {
            return hit.optionId
        }
        return optionId(for: decision)
    }
}

public enum AcpPermissionOutcome: Hashable, Sendable {
    case selected(optionId: String)
    /// 真的取消了：手机点了中断、agent 被停用或 BotBus 退出。
    case cancelled
    /// BotBus 没有答案：被同一会话的新请求顶掉、这一轮已经结束。子进程模式下按 ACP 回 cancelled（`json`）；
    /// 反向连接上回 `AcpProtocol.noAnswerCode` 错误，agent 继续等终端（见 `AcpConnector.handleAgentRequest`）。
    case unanswered

    public var json: JSONValue {
        switch self {
        case .selected(let optionId): ["outcome": ["outcome": "selected", "optionId": .string(optionId)]]
        case .cancelled, .unanswered: ["outcome": ["outcome": "cancelled"]]
        }
    }

    static var noAnswer: JSONRPCError {
        JSONRPCError(code: AcpProtocol.noAnswerCode, message: "BotBus 没有答案")
    }
}

/// `session/list` 里的一条。
public struct AcpSessionInfo: Hashable, Sendable {
    public var sessionId: String
    public var cwd: String
    public var title: String?
    public var updatedAt: Date?

    public init?(json: JSONValue) {
        guard let id = json["sessionId"]?.stringValue, !id.isEmpty,
              let cwd = json["cwd"]?.stringValue else { return nil }
        sessionId = id
        self.cwd = cwd
        title = json["title"]?.stringValue
        updatedAt = json["updatedAt"]?.stringValue.flatMap(Self.parseDate)
    }

    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// `session/new` / `session/load` 里的一个 MCP server。env 在 ACP 里是 `[{name, value}]`。
public struct AcpMcpServer: Hashable, Sendable {
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [String: String]

    public init(name: String, command: String, args: [String], env: [String: String]) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }

    /// 把 `botbus` MCP 注给 agent：第三方 agent 不用做任何适配就能把产物回传给手机。
    public static func botbus(_ injection: AgentToolsInjection) -> AcpMcpServer {
        AcpMcpServer(name: AgentToolsInjection.mcpServerName, command: injection.configuration.cliPath,
                     args: ["mcp"], env: injection.environment)
    }

    public var json: JSONValue {
        [
            "name": .string(name),
            "command": .string(command),
            "args": .array(args.map(JSONValue.string)),
            "env": .array(env.sorted { $0.key < $1.key }.map { ["name": .string($0.key), "value": .string($0.value)] }),
        ]
    }
}

/// 反向扩展的握手（spec「反向扩展 → 握手」）。
public struct AcpHello: Hashable, Sendable {
    public struct Capabilities: Hashable, Sendable {
        public var prompt: Bool
        public var cancel: Bool
        public var newSession: Bool

        public init(prompt: Bool = false, cancel: Bool = false, newSession: Bool = false) {
            self.prompt = prompt
            self.cancel = cancel
            self.newSession = newSession
        }
    }

    public var id: String
    public var version: Int64
    public var pid: Int64?
    public var capabilities: Capabilities

    public init?(params: JSONValue) {
        guard let id = params["id"]?.stringValue, let version = params["version"]?.intValue else { return nil }
        self.id = id
        self.version = version
        pid = params["pid"]?.intValue
        let caps = params["capabilities"]
        capabilities = Capabilities(prompt: caps?["prompt"]?.boolValue ?? false,
                                    cancel: caps?["cancel"]?.boolValue ?? false,
                                    newSession: caps?["newSession"]?.boolValue ?? false)
    }

    static func rejection(_ reason: String) -> JSONValue { ["accepted": false, "reason": .string(reason)] }
}
