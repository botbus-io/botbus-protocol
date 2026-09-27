import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 一个 `AcpConnector` 把 ACP 会话对应成哪种 BotBus 任务。
///
/// - `.acp(connectorId:)`：第三方 agent（协议 2.13），任务 id `acp:<connectorId>:<sessionId>`，
///   `source = .acp`，带 `connectorId`。`AcpHub` 建的连接器都是这一种。
/// - `.builtin(source)`：一档来源借 ACP 驱动（协议 3.1 的 DeepSeek Harness），任务 id `<source>:<sessionId>`，
///   `source` 就是它，**不带** `connectorId`。只有 `sessionId` 非空才认。
///
/// 连接器自己的 `id`（健康回报、本机记录 `AcpSessionArchive` 的键、日志）仍是 `AcpAgentSpec.id`，与身份无关；
/// 一档来源的 spec id 取来源原始值（`dsh`），它在 `AcpDiscovery.reservedIds` 里，不会和第三方 agent 撞。
public enum AcpTaskIdentity: Hashable, Sendable {
    case acp(connectorId: String)
    case builtin(TaskSource)

    public var source: TaskSource {
        switch self {
        case .acp: .acp
        case .builtin(let source): source
        }
    }

    /// 外发任务上的 `connectorId`：只有第三方 agent 带。
    public var connectorId: String? {
        switch self {
        case .acp(let connectorId): connectorId
        case .builtin: nil
        }
    }

    public func taskId(sessionId: String) -> String {
        switch self {
        case .acp(let connectorId): AcpTaskID.make(connectorId: connectorId, sessionId: sessionId)
        case .builtin(let source): "\(source.rawValue):\(sessionId)"
        }
    }

    /// 任务 id → 会话 id；不属于这个身份（前缀或 connectorId 不对、会话 id 为空）返回 nil。
    public func sessionId(taskId: String) -> String? {
        switch self {
        case .acp(let connectorId):
            guard let parsed = AcpTaskID.parse(taskId), parsed.connectorId == connectorId else { return nil }
            return parsed.sessionId
        case .builtin(let source):
            let prefix = "\(source.rawValue):"
            guard taskId.hasPrefix(prefix) else { return nil }
            let sessionId = String(taskId.dropFirst(prefix.count))
            return sessionId.isEmpty ? nil : sessionId
        }
    }
}

/// 一个 ACP 会话的对话记录，由 `session/update` 一条条拼出来（ACP 没有"读历史"的调用，只能靠 `session/load` 重放）。
///
/// 消息 id 按"第几轮-第几段"编：用户消息开启新的一轮。同一段历史重放时编出来的 id 一样，
/// 手机据此去重（协议要求同一条消息重复拉取时 id 稳定）。工具行用 `tool-<toolCallId>`。
struct AcpTranscript: Hashable, Sendable {
    static let maxEntries = 500

    private struct Item: Hashable, Sendable {
        var id: String
        var role: Message.Role
        var text: String
        var images: [AcpImage]
        var createdAt: String
    }

    private var items: [Item] = []
    private var turn = 0
    private var segment = 0
    /// `startTurn()` 打的标记：下一条真正落地的内容（不管角色）都要另起一轮，不能跟上一轮的
    /// 最后一条合并——反向扩展在终端里发起新一轮时不一定带得动用户消息（`beginTurn(prompt: "")`），
    /// 全靠这个标记把 Agent 的第一句回复和上一轮的尾巴分开。只有真正落地一条新 item（`appendText`
    /// 走到追加分支）才清掉；空 prompt 不消费它。重放（`session/load` 之后逐条 `apply`）从不调用
    /// `startTurn`，所以重放出来的 id 与之前完全一样。
    private var pendingNewTurn = false
    /// 这份记录从会话第一条起就齐全：BotBus 自己 `session/new` 建的、或 `session/load` 完整重放过的。
    /// 从 store 的记录接过来的、`session/resume` 接上的（不重放）、被上限淘汰过（`reset()`）的都是 false——
    /// 里面至多只有之后的几轮。`AcpConnector.completeTranscript` 据此决定要不要让外层自己读历史。
    var isComplete = false

    var isEmpty: Bool { items.isEmpty }

    mutating func reset() {
        self = AcpTranscript()
    }

    /// 标记"下一条内容要另起一轮"。真人一轮开始时都要调用（不管这一轮的 prompt 是不是空的），
    /// 防止被打断的上一轮尾巴和这一轮的第一句粘在一起（同角色连续片段默认合并）。
    mutating func startTurn() {
        pendingNewTurn = true
    }

    mutating func appendText(_ role: Message.Role, _ text: String, images: [AcpImage] = [], at createdAt: String) {
        guard !text.isEmpty || !images.isEmpty else { return }
        if let last = items.last, last.role == role, role != .tool, !pendingNewTurn {
            items[items.count - 1].text += text
            items[items.count - 1].images += images
            return
        }
        if role == .user || pendingNewTurn {
            turn += 1
            segment = 0
        }
        segment += 1
        pendingNewTurn = false
        items.append(Item(id: "\(turn)-\(segment)", role: role, text: text, images: images, createdAt: createdAt))
        trim()
    }

    mutating func tool(_ call: AcpToolCall, at createdAt: String) {
        let id = "tool-\(call.toolCallId)"
        let text = call.title ?? call.kind ?? "tool"
        if let index = items.lastIndex(where: { $0.id == id }) {
            items[index].text = text
            return
        }
        items.append(Item(id: id, role: .tool, text: text, images: [], createdAt: createdAt))
        trim()
    }

    var entries: [TranscriptEntry] {
        items.map { item in
            TranscriptEntry(
                message: Message(id: item.id, role: item.role, text: truncateMessage(item.text), createdAt: item.createdAt),
                images: item.images.compactMap { ImageSource(base64: $0.base64, contentType: $0.mimeType) })
        }
    }

    private mutating func trim() {
        if items.count > Self.maxEntries { items.removeFirst(items.count - Self.maxEntries) }
    }
}

/// 一个 ACP 会话在 BotBus 这边的全部状态：外发的任务记录、对话记录、这一轮攒的回复、挂起的审批。
/// 纯值类型、不碰 IO，状态推算（spec「状态对应」）全在这里测。
///
/// 流式片段只进对话记录、不改任务记录——否则每个 token 都是一次 `taskUpdated`。
struct AcpSessionState: Hashable, Sendable {
    static let summaryLimit = 200

    var record: TaskRecord
    var transcript = AcpTranscript()
    private(set) var running = false
    private(set) var pending: AcpPermissionRequest?
    private var turnText = ""
    private var tools: [String: AcpToolCall] = [:]
    /// 标题定下来了（agent 给过，或者首条 prompt 已经用过）就不再改。
    private var titleLocked = false
    /// 这一轮 `beginTurn` 是否已经记了一条非空的用户消息（文字或图）。true 时这一轮里再收到的
    /// `user_message_chunk` 一律当成 BotBus 自己发的 `session/prompt` 被 agent 回显，直接丢掉，
    /// 不然手机上会看见同一句话出现两次。
    private var promptRecordedThisTurn = false
    /// `setPending` 之前的状态，`clearPending` 用它复原——不能无脑写 `.running`，
    /// 一轮已经结束之后才收到的审批（理论上不该发生，但别把任务卡在 `waitingApproval`）也要能退回去。
    private var statusBeforePending: TaskStatus = .idle

    init(record: TaskRecord) {
        self.record = record
        titleLocked = record.title != record.projectName && !record.title.isEmpty
    }

    static func newRecord(connectorId: String, sessionId: String, cwd: String, title: String?,
                          origin: TaskOrigin, controllable: Bool, at timestamp: String) -> TaskRecord {
        newRecord(identity: .acp(connectorId: connectorId), sessionId: sessionId, cwd: cwd, title: title,
                  origin: origin, controllable: controllable, at: timestamp)
    }

    /// 新会话的任务记录：id、`source`、`connectorId` 按 `identity` 定（见 `AcpTaskIdentity`）。
    static func newRecord(identity: AcpTaskIdentity, sessionId: String, cwd: String, title: String?,
                          origin: TaskOrigin, controllable: Bool, at timestamp: String) -> TaskRecord {
        let projectName = SessionFormatting.projectName(cwd)
        let trimmed = SessionFormatting.truncate(singleLine(title ?? ""), SessionFormatting.titleLimit)
        return TaskRecord(id: identity.taskId(sessionId: sessionId), agentId: "", source: identity.source,
                          title: trimmed.isEmpty ? (projectName.isEmpty ? sessionId : projectName) : trimmed,
                          projectPath: cwd, projectName: projectName, status: .idle, origin: origin,
                          controllable: controllable, startedAt: timestamp, updatedAt: timestamp,
                          connectorId: identity.connectorId)
    }

    /// 一轮开始。`prompt` 为空（反向扩展的 `_botbus/turn started`）时不记用户消息，但仍要
    /// `startTurn()`：不然终端里敲的下一句 agent 回复会跟上一轮的回复粘在一起。
    mutating func beginTurn(prompt: String, images: [AcpImage], at timestamp: String) {
        transcript.startTurn()
        transcript.appendText(.user, prompt, images: images, at: timestamp)
        let line = Self.singleLine(prompt)
        if !titleLocked, !line.isEmpty {
            record.title = SessionFormatting.truncate(line, SessionFormatting.titleLimit)
            titleLocked = true
        }
        running = true
        turnText = ""
        pending = nil
        promptRecordedThisTurn = !prompt.isEmpty || !images.isEmpty
        record.pendingRequest = nil
        record.status = .running
        record.updatedAt = timestamp
    }

    mutating func apply(_ update: AcpSessionUpdate, at timestamp: String) {
        switch update {
        case .userMessage(let text, let images):
            // 这一轮的 prompt 是 BotBus 自己经 `session/prompt` 发的，agent 常把它原样回显成
            // `user_message_chunk`——运行中且已经记过 prompt 时，这条八成是回显，不是新消息。
            guard !(running && promptRecordedThisTurn) else { return }
            transcript.appendText(.user, text, images: images, at: timestamp)
        case .agentMessage(let text, let images):
            transcript.appendText(.agent, text, images: images, at: timestamp)
            if running { turnText += text }
        case .toolCall(let call):
            tools[call.toolCallId] = call
            transcript.tool(call, at: timestamp)
        case .toolCallUpdate(let update):
            let merged = tools[update.toolCallId].map { $0.merging(update) } ?? update
            tools[update.toolCallId] = merged
            transcript.tool(merged, at: timestamp)
        case .sessionInfo(let title):
            let line = Self.singleLine(title ?? "")
            guard !line.isEmpty else { return }
            record.title = SessionFormatting.truncate(line, SessionFormatting.titleLimit)
            titleLocked = true
        case .thought, .other:
            return
        }
    }

    mutating func setPending(_ request: AcpPermissionRequest, at timestamp: String) {
        let call = tools[request.toolCall.toolCallId].map { $0.merging(request.toolCall) } ?? request.toolCall
        // 旧审批还挂着时来了新的（连接器会先把旧的回成取消）：保留最初那个状态，别记成 waitingApproval。
        if pending == nil { statusBeforePending = record.status }
        pending = request
        record.status = .waitingApproval
        record.pendingRequest = PendingRequest(
            id: call.toolCallId, kind: call.pendingKind,
            summary: SessionFormatting.truncate(Self.singleLine(call.title ?? call.kind ?? "工具调用"), Self.summaryLimit),
            detail: call.detail.map { SessionFormatting.truncate($0, SessionFormatting.detailLimit) },
            questions: request.pendingQuestions)
        record.updatedAt = timestamp
    }

    /// 复原成挂起审批之前的状态：一轮还在跑就是 `.running`，否则退回 `setPending` 记下的状态
    /// （不能无脑写 `.running`——一轮已经结束后才清审批时会把已经 `.completed` 的任务错改回运行中）。
    mutating func clearPending(at timestamp: String) {
        guard pending != nil else { return }
        pending = nil
        record.pendingRequest = nil
        record.status = running ? .running : statusBeforePending
        record.updatedAt = timestamp
    }

    /// 一轮结束。`error` 非 nil 表示这一轮出错（JSON-RPC 报错、进程崩了）。
    mutating func endTurn(_ stopReason: AcpStopReason?, error: String?, at timestamp: String) {
        running = false
        promptRecordedThisTurn = false
        pending = nil
        record.pendingRequest = nil
        let reply = turnText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error {
            record.status = .failed
            record.lastMessage = SessionFormatting.truncate(reply.isEmpty ? error : reply, SessionFormatting.lastMessageLimit)
        } else {
            let reason = stopReason ?? .endTurn
            switch reason {
            case .endTurn: record.status = .completed
            case .cancelled: record.status = .interrupted
            case .refusal, .maxTokens, .maxTurnRequests: record.status = .failed
            }
            if !reply.isEmpty {
                record.lastMessage = SessionFormatting.truncate(reply, SessionFormatting.lastMessageLimit)
            } else if let explanation = Self.explanation(reason) {
                record.lastMessage = explanation
            }
        }
        turnText = ""
        record.updatedAt = timestamp
    }

    private static func explanation(_ reason: AcpStopReason) -> String? {
        switch reason {
        case .refusal: "agent 拒绝继续这次请求"
        case .maxTokens: "回复达到了 token 上限"
        case .maxTurnRequests: "这一轮的模型请求次数超过了上限"
        case .endTurn, .cancelled: nil
        }
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
