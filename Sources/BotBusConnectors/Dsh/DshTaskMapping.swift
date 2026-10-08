import Foundation
import BotBusProtocol
import BotBusConnectorKit

// DeepSeek Harness（协议 3.1）的纯映射：web 列表 / 扫盘结果 / follow 流 / waterfall → `TaskRecord`。
// 不碰 IO，`DshConnector` 的对账与实时发布都走这里，规则在 `DshTaskMappingTests` 里测。

/// 一个会话在列表里（web 的 `session/list` 或扫盘）的样子，拼任务记录用。
struct DshSessionFacts: Hashable, Sendable {
    var sessionId: String
    var cwd: String
    var title: String?
    var createdAt: Date?
    var updatedAt: Date
    /// web 说它正在跑（`running` 或 `api-session/status true`）。
    var webRunning = false
    /// 扫盘看到"开了一轮还没收尾"，而且日志刚刚还在写：多半是别的 dsh 进程（TUI、headless）正在跑。
    var openTurnRecent = false

    /// web 列表的一项。空白会话、subagent、没有 cwd 或时间的不要（web 自己的列表也不列没有 cwd 的）。
    init?(web summary: DshWebSessionSummary) {
        guard !summary.blank, !summary.isSubagent, let cwd = summary.cwd, !cwd.isEmpty,
              let updated = summary.updatedAt else { return nil }
        self.init(sessionId: summary.sessionId, cwd: cwd, title: summary.title, createdAt: nil, updatedAt: updated,
                  webRunning: summary.running)
    }

    /// 扫盘的一项（扫描器已经滤掉了空白与 subagent）。`openTurnWindow` 内还在写日志的未收尾轮次算在跑。
    init(scanned summary: DshSessionSummary, now: Date, openTurnWindow: TimeInterval = DshTaskMapping.openTurnWindow) {
        self.init(sessionId: summary.sessionId, cwd: summary.cwd, title: summary.title, createdAt: summary.createdAt,
                  updatedAt: summary.updatedAt,
                  openTurnRecent: summary.hasOpenTurn && now.timeIntervalSince(summary.updatedAt) <= openTurnWindow)
    }

    init(sessionId: String, cwd: String, title: String?, createdAt: Date?, updatedAt: Date,
         webRunning: Bool = false, openTurnRecent: Bool = false) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.webRunning = webRunning
        self.openTurnRecent = openTurnRecent
    }
}

/// 一次工具调用（`tool/call`）：审批卡片要拿它的参数显示要跑的命令。
struct DshToolCall: Hashable, Sendable {
    var name: String
    /// 原样的参数 JSON 字符串。
    var arguments: String?

    /// 参数里的 `command`（bash 一类工具）。
    var command: String? {
        guard let arguments, let json = try? JSONValue.decode(arguments) else { return nil }
        return json["command"]?.stringValue.flatMap { $0.trimmed.isEmpty ? nil : $0 }
    }
}

/// follow 流（`session/follow` 的 snapshot 与之后的 event）累积出来的实时状态。只为 web 正在跑的会话攒。
struct DshLiveState: Hashable, Sendable {
    static let maxTools = 64

    var running = false
    var lastMessage: String?
    var turnEnd: DshTurnEndReason?
    var title: String?
    var updatedAt: Date?
    var tools: [String: DshToolCall] = [:]
    /// `approval/asked` 的 id → callId（`approval/decided` 只带 id）。
    var approvals: [String: String] = [:]
    /// 这一轮到现在的最后一句回复：轮次以报错收尾又没说过话时，`lastMessage` 用错误文本。
    private var repliedThisTurn = false
    private var toolOrder: [String] = []

    /// 喂一条事件。返回这条事件让哪次审批落了定（`approval/decided` 对应的 callId），好让连接器清掉挂着的请求。
    @discardableResult
    mutating func apply(_ event: DshSessionEvent) -> String? {
        guard !event.isReplacement else { return nil }
        switch event.type {
        case "turn/start":
            running = true
            turnEnd = nil
            repliedThisTurn = false
            touch(event.time)
        case "turn/end":
            running = false
            let reason = event.turnEndReason
            turnEnd = reason
            if !repliedThisTurn, case .error(let message?) = reason, !message.trimmed.isEmpty {
                lastMessage = SessionFormatting.truncate(message, SessionFormatting.lastMessageLimit)
            }
            touch(event.time)
        case "assistant/message":
            if let text = event.text?.trimmed, !text.isEmpty {
                lastMessage = SessionFormatting.truncate(text, SessionFormatting.lastMessageLimit)
                repliedThisTurn = true
            }
            touch(event.time)
        case "user/message":
            if event.sourceKind == "user" { touch(event.time) }
        case "session/title":
            if let title = event.title?.trimmed, !title.isEmpty { self.title = title }
        case "tool/call":
            guard let callId = event.data["callId"]?.stringValue, !callId.isEmpty else { return nil }
            if tools[callId] == nil { toolOrder.append(callId) }
            tools[callId] = DshToolCall(name: event.data["name"]?.stringValue ?? "tool",
                                        arguments: event.data["arguments"]?.stringValue)
            if toolOrder.count > Self.maxTools { tools.removeValue(forKey: toolOrder.removeFirst()) }
        case "approval/asked":
            if let id = event.data["id"]?.stringValue, let callId = event.data["callId"]?.stringValue {
                approvals[id] = callId
            }
        case "approval/decided":
            guard let id = event.data["id"]?.stringValue else { return nil }
            return approvals.removeValue(forKey: id)
        default:
            break
        }
        return nil
    }

    private mutating func touch(_ time: Date?) {
        guard let time else { return }
        if updatedAt.map({ time > $0 }) ?? true { updatedAt = time }
    }
}

enum DshTaskMapping {
    static let identity = AcpTaskIdentity.builtin(.dsh)
    /// 扫盘时"开着的一轮"只在日志这么久之内还在写时才算在跑：进程在一轮中途没了的会话不会永远挂着运行中。
    static let openTurnWindow: TimeInterval = 5 * 60
    static let summaryLimit = 200

    /// `.dsh` 的全量对账列表（spec「看见」）：
    /// - 底子是 web 列表（连着时）或扫盘结果，只要 7 天窗口里的；
    /// - 同一个会话在 `acp`（`AcpConnector.staticTasks()`，BotBus 自己拉起或接上过的）里也有时，来源（`.watch`）与标题以它为准，
    ///   状态与最后一条消息取两边更新的那一份；只在 `acp` 里有的照样列出；
    /// - `controllable` 统一按"现在有没有路可走"（web 连着，或者有可执行文件能 `session/resume`）。
    static func merged(base: [DshSessionFacts], acp: [TaskRecord], live: [String: DshLiveState], controllable: Bool,
                       now: Date) -> [TaskRecord] {
        var acpById: [String: TaskRecord] = [:]
        for record in acp where record.source == .dsh { acpById[record.id] = record }
        var result: [String: TaskRecord] = [:]
        for facts in base where now.timeIntervalSince(facts.updatedAt) <= SessionFormatting.recentWindow {
            let taskId = identity.taskId(sessionId: facts.sessionId)
            result[taskId] = record(facts: facts, live: live[facts.sessionId], pending: nil, acp: acpById[taskId],
                                    controllable: controllable, now: now)
        }
        for (id, record) in acpById where result[id] == nil {
            guard let updated = date(record.updatedAt), now.timeIntervalSince(updated) <= SessionFormatting.recentWindow else {
                continue
            }
            var copy = record
            copy.controllable = controllable
            result[id] = copy
        }
        return result.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 一个会话的任务记录。状态：挂着 waterfall → 待审批 / 待回答；web 在跑或 follow 看到开着的一轮 → 运行中；
    /// 否则最后一次 `turn/end` 的原因；都不知道就按时间（24 小时内 completed，之外 idle）；扫盘看到刚刚还在写的未收尾轮次算运行中。
    static func record(facts: DshSessionFacts, live: DshLiveState?, pending: DshWaterfall?, acp: TaskRecord?,
                       controllable: Bool, now: Date) -> TaskRecord {
        let updated = max(facts.updatedAt, live?.updatedAt ?? .distantPast)
        var record = AcpSessionState.newRecord(identity: identity, sessionId: facts.sessionId, cwd: facts.cwd,
                                               title: live?.title ?? facts.title, origin: .desktop,
                                               controllable: controllable, at: ProtocolJSON.timestamp(updated))
        record.startedAt = ProtocolJSON.timestamp(min(facts.createdAt ?? updated, updated))
        record.lastMessage = live?.lastMessage
        let mapped = pending.flatMap { pendingRequest($0, live: live) }
        let running = facts.webRunning || live?.running == true
        if let mapped {
            record.status = mapped.status
            record.pendingRequest = mapped.request
        } else if running {
            record.status = .running
        } else if facts.openTurnRecent, facts.updatedAt > (live?.updatedAt ?? .distantPast) {
            // 我们上次跟到的收尾之后日志又动了：别的 dsh 进程在接着跑。
            record.status = .running
        } else if let end = live?.turnEnd {
            record.status = aged(end.status, updated: updated, now: now)
        } else {
            record.status = aged(.completed, updated: updated, now: now)
        }
        guard let acp else { return record }
        if record.lastMessage == nil { record.lastMessage = acp.lastMessage }
        // BotBus 自己跑过的更新：它知道得更清楚（最后一条消息、失败原因）。在跑、挂着请求的以实时数据为准。
        if mapped == nil, !running, !facts.openTurnRecent, acp.updatedAt >= record.updatedAt {
            record.status = acp.status
            record.lastMessage = acp.lastMessage ?? record.lastMessage
            record.pendingRequest = acp.pendingRequest
            record.updatedAt = acp.updatedAt
        }
        record.origin = acp.origin
        if !isPlaceholderTitle(acp) { record.title = acp.title }
        if acp.startedAt < record.startedAt { record.startedAt = acp.startedAt }
        return record
    }

    /// `newRecord` 没有标题时填的是项目名或会话 id：那不算"BotBus 给的标题"，不拿它盖掉 dsh 起的标题。
    static func isPlaceholderTitle(_ record: TaskRecord) -> Bool {
        let native = identity.sessionId(taskId: record.id) ?? ""
        return record.title.isEmpty || record.title == record.projectName || record.title == native
    }

    /// 已结束的状态放了 24 小时以上算 idle（同 ACP 的静态会话）。
    static func aged(_ status: TaskStatus, updated: Date, now: Date) -> TaskStatus {
        guard [.completed, .failed, .interrupted, .idle].contains(status) else { return status }
        return now.timeIntervalSince(updated) > SessionFormatting.idleAfter ? .idle : status
    }

    // MARK: - waterfall → PendingRequest

    /// 审批与提问（协议 2.14 的 `questions`）。`PendingRequest.id` 用 waterfall 的 `eventId`——回答就靠它。
    ///
    /// - 审批：bash 一类工具、且 follow 流里见过这次调用的 `command` 时记 `command`（摘要「执行命令：…」，详情是 dsh 给的理由）；
    ///   其余记 `permission`（摘要是理由，没有理由时「<工具> 请求授权」，详情是参数原文）。电脑写的摘要带协议 3.11 的短语。
    ///   dsh 的审批只有"允许这一次 / 拒绝"，不带「允许范围」。
    /// - 提问：`input`，`questions` 照搬（选项只有名字）；`question` 是写好选项的纯文字，给不认 `questions` 的旧手机看。
    static func pendingRequest(_ waterfall: DshWaterfall, live: DshLiveState?) -> (status: TaskStatus, request: PendingRequest)? {
        switch waterfall.request {
        case .approval(let toolName, let callId, let reason):
            let call = callId.flatMap { live?.tools[$0] }
            let tool = toolName ?? call?.name
            let reasonLine = reason.map(AcpSessionState.singleLine).flatMap { $0.isEmpty ? nil : $0 }
            if isCommandTool(tool), let command = call?.command {
                let phrase = RequestPhrase.runCommand(SessionFormatting.truncate(AcpSessionState.singleLine(command), summaryLimit))
                return (.waitingApproval, PendingRequest(
                    id: waterfall.eventId, kind: .command,
                    summary: SessionFormatting.truncate(phrase.chineseText, summaryLimit),
                    detail: reason.map { SessionFormatting.truncate($0, SessionFormatting.detailLimit) },
                    summaryPhrase: phrase))
            }
            let phrase = reasonLine == nil ? RequestPhrase.requestPermission(tool: tool) : nil
            return (.waitingApproval, PendingRequest(
                id: waterfall.eventId, kind: .permission,
                summary: SessionFormatting.truncate(reasonLine ?? phrase?.chineseText ?? "", summaryLimit),
                detail: (call?.arguments ?? reason).map { SessionFormatting.truncate($0, SessionFormatting.detailLimit) },
                summaryPhrase: phrase))
        case .questions(let questions):
            let mapped = pendingQuestions(questions)
            guard let mapped, let first = mapped.first else { return nil }
            let line = AcpSessionState.singleLine(first.header ?? first.question)
            let phrase = line.isEmpty ? RequestPhrase.awaitingAnswer(agent: "DeepSeek Harness") : nil
            return (.waitingInput, PendingRequest(
                id: waterfall.eventId, kind: .input,
                summary: SessionFormatting.truncate(phrase?.chineseText ?? line, summaryLimit),
                question: plainText(mapped), questions: mapped, summaryPhrase: phrase))
        case .other:
            return nil
        }
    }

    static func isCommandTool(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name.hasPrefix("bash") || name.hasPrefix("pwsh") || name == "shell" || name == "terminal"
    }

    static func pendingQuestions(_ questions: [DshQuestion]) -> [PendingQuestion]? {
        let mapped = questions.prefix(PendingQuestion.maxQuestions).compactMap { item -> PendingQuestion? in
            let detail = item.detail?.trimmed ?? ""
            let text = [item.question.trimmed, detail].filter { !$0.isEmpty }.joined(separator: "\n")
            guard !text.isEmpty else { return nil }
            return PendingQuestion(id: item.id, question: SessionFormatting.truncate(text, SessionFormatting.detailLimit),
                                   header: item.header.flatMap { $0.trimmed.isEmpty ? nil : $0 },
                                   multiSelect: item.multiSelect,
                                   options: item.options.prefix(PendingQuestion.maxOptions).map { PendingOption(label: $0) })
        }
        return mapped.isEmpty ? nil : mapped
    }

    static func plainText(_ questions: [PendingQuestion]) -> String {
        let blocks = questions.map { question -> String in
            var lines = [question.question + (question.allowsMultiple ? "（可多选）" : "")]
            for (index, option) in question.options.enumerated() { lines.append("\(index + 1). \(option.label)") }
            return lines.joined(separator: "\n")
        }
        return SessionFormatting.truncate(blocks.joined(separator: "\n\n"), SessionFormatting.detailLimit)
    }

    // MARK: - 手机的回答 → dsh 的回答

    /// `approve(allow, answers:)`：每道题取手机给的值，是选项名的进 `selected`，不是的（手机上直接打的字）拼进 `custom`；
    /// 单选题有 `custom` 时 `selected` 留空（dsh：`custom` 盖过选项），只取第一个选项。手机没答的题记跳过。
    static func answers(for questions: [DshQuestion], from phone: [String: [String]]) -> [DshQuestionAnswer] {
        questions.map { question in
            let picked = (phone[question.id] ?? []).map(\.trimmed).filter { !$0.isEmpty }
            let options = picked.filter { question.options.contains($0) }
            let typed = picked.filter { !question.options.contains($0) }
            let custom = typed.isEmpty ? nil : typed.joined(separator: ", ")
            if question.multiSelect { return DshQuestionAnswer(id: question.id, selected: options, custom: custom) }
            if let custom { return DshQuestionAnswer(id: question.id, selected: [], custom: custom) }
            return DshQuestionAnswer(id: question.id, selected: Array(options.prefix(1)))
        }
    }

    /// 挂着提问时手机直接发了一句话（`followUp`）：所有题都用这句话作答。
    static func answers(for questions: [DshQuestion], text: String) -> [DshQuestionAnswer] {
        questions.map { DshQuestionAnswer(id: $0.id, selected: [], custom: text) }
    }

    /// 「跳过」（手机上点了拒绝）：每道题都不选，dsh 把它当作用户跳过了这些问题，这一轮接着跑（不是中断）。
    static func skipped(_ questions: [DshQuestion]) -> [DshQuestionAnswer] {
        questions.map { DshQuestionAnswer(id: $0.id, selected: []) }
    }

    static func date(_ timestamp: String) -> Date? { ISO8601DateFormatter().date(from: timestamp) }
}
