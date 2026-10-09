import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 只读地把 Hermes Agent 的 `~/.hermes/state.db` 映射成协议模型。
///
/// 和 `CodexThreadReader` 同一个用法：每次调用新开库、读完即关（局部变量出作用域就 `sqlite3_close`），
/// 不跨轮持有 WAL 读锁；`SQLiteDatabase` 的 `immutable=1` 兜底同样适用于 Hermes 退出后只剩主文件的库。
///
/// **schema 按列探测**：Hermes 当前是 v30，但用户机器上的库可能是更老的版本（缺 `archived` /
/// `hidden` / `last_activity_at` / `active` 等列）。所以先查 `PRAGMA table_info`，只拿存在的列拼 SQL——
/// 直接写死列名的后果是老库每一轮都报 "no such column"，菜单栏一条 Hermes 会话都看不到。
public struct HermesStateReader: Sendable {
    public static let maxTasks = 200
    /// `ended_at` 为空、且最近这么久内有过动静，才算"正在跑"。
    public static let runningWindow: TimeInterval = 120
    /// 这些 `end_reason` 说明会话是出错结束的。
    static let failedEndReasons: Set<String> = ["error", "agent_error", "content_filter"]
    /// 一轮已经收尾的 assistant `finish_reason`（OpenAI 形状）。`tool_calls` 不在里面：那是一轮的中间步。
    static let finishedReasons: Set<String> = ["stop", "length", "end_turn", "content_filter"]

    public let databasePath: String
    /// 没有 `cwd` 的会话（Hermes 桌面端、Telegram 等渠道、cron）归到这个目录：手机按项目分组要一个路径，
    /// 续聊也要一个起进程的地方。默认是用户主目录，和 Hermes 命令行不带 `--in` 时一样。
    public let fallbackDirectory: String
    private let now: @Sendable () -> Date

    public init(databasePath: String, fallbackDirectory: String = HermesStateReader.homeDirectory,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.databasePath = databasePath
        self.fallbackDirectory = fallbackDirectory
        self.now = now
    }

    /// 不管库在不在都能建；读的时候才判断（`readSnapshot` 抛 `SessionSourceUnavailable`）。
    public init(paths: HermesPaths, fallbackDirectory: String = HermesStateReader.homeDirectory,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(databasePath: paths.hermesHome.appendingPathComponent("state.db").path,
                  fallbackDirectory: fallbackDirectory, now: now)
    }

    public static var homeDirectory: String { FileManager.default.homeDirectoryForCurrentUser.path }

    // MARK: - 快照

    /// 7 天内有活动、没归档/隐藏、不是被压缩掉的旧会话，活动时间降序，最多 200 条。
    ///
    /// Hermes 桌面端、Telegram 等渠道、cron 的会话没有 `cwd`，归到 `fallbackDirectory`（用户主目录）这个项目下，
    /// 照样进快照（用户要求手机上也能看到桌面端发起的会话）。
    /// 库不存在抛 `SessionSourceUnavailable`（观察者据此不对账，一条都不摘）；缺表、忙锁照常抛错，
    /// 由观察者按连续失败次数报警。
    public func readSnapshot(agentId: String) throws -> (tasks: [TaskRecord], projects: [Project]) {
        let snapshot = try readObservedSnapshot(agentId: agentId)
        return (snapshot.tasks, snapshot.projects)
    }

    /// 本机通知上下文不进协议；任务列表和通知分组来自同一轮读库。
    public func readObservedSnapshot(agentId: String) throws -> ObservedSessionSnapshot {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw SessionSourceUnavailable("未找到 Hermes 数据库：\(databasePath)")
        }
        let database = try SQLiteDatabase(path: databasePath)
        return try readTasks(database: database, agentId: agentId)
    }

    func readTasks(database: SQLiteDatabase, agentId: String) throws -> ObservedSessionSnapshot {
        let sessionColumns = try HermesSQL.columns(of: "sessions", in: database)
        guard !sessionColumns.isEmpty else { throw HermesSchemaError("state.db 里没有 sessions 表") }
        guard sessionColumns.contains("id") else { throw HermesSchemaError("sessions 表缺 id 列") }
        let activityParts = ["last_activity_at", "ended_at", "started_at"].filter(sessionColumns.contains)
        guard !activityParts.isEmpty else { throw HermesSchemaError("sessions 表没有任何时间列") }
        let activity = activityParts.count == 1 ? activityParts[0] : "COALESCE(\(activityParts.joined(separator: ", ")))"

        var filters = ["\(activity) > ?"]
        if sessionColumns.contains("archived") { filters.append("COALESCE(archived, 0) = 0") }
        if sessionColumns.contains("hidden") { filters.append("COALESCE(hidden, 0) = 0") }
        // 压缩会以 end_reason='compression' 结束旧会话、新开一行接着聊：只显示链条末端。
        if sessionColumns.contains("end_reason") { filters.append("(end_reason IS NULL OR end_reason != 'compression')") }

        let wanted = ["id", "source", "cwd", "title", "started_at", "ended_at", "last_activity_at", "end_reason"]
        let selected = wanted.filter(sessionColumns.contains).joined(separator: ", ")
        let current = now()
        let since = current.timeIntervalSince1970 - SessionFormatting.recentWindow
        let rows = try database.query("""
            SELECT \(selected), \(activity) AS activity_at FROM sessions
            WHERE \(filters.joined(separator: " AND "))
            ORDER BY activity_at DESC
            LIMIT ?
            """, [.real(since), .integer(Int64(Self.maxTasks))])

        let messages = try HermesMessageQueries(database: database)
        var tasks: [TaskRecord] = []
        var notifications: [String: ObservedTaskNotification] = [:]
        for row in rows {
            guard let id = HermesSQL.text(row["id"]), !id.isEmpty,
                  let activitySeconds = HermesSQL.seconds(row["activity_at"]) else { continue }
            let ownCwd = HermesSQL.directory(row["cwd"])
            let cwd = ownCwd ?? fallbackDirectory
            let activityAt = Date(timeIntervalSince1970: activitySeconds)
            let startedAt = HermesSQL.seconds(row["started_at"]).map(Date.init(timeIntervalSince1970:)) ?? activityAt
            let endedAt = HermesSQL.seconds(row["ended_at"])
            let endReason = HermesSQL.text(row["end_reason"])
            let projectName = SessionFormatting.projectName(cwd)

            // 会话结束不等于这一轮成功：cron 即使失败也可能以 cron_complete 收尾。
            // 只看最新 active 消息，避免重试的新 user 或成功回答沿用上一轮的 failed_turn。
            let turn = try messages.lastTurnState(sessionID: id)
            let status = Self.status(endReason: endReason, ended: endedAt != nil, activityAt: activityAt,
                                     now: current, turnFinished: turn.finished, turnFailed: turn.failed)
            let assistantText = try messages.lastAssistantText(sessionID: id)
            let lastMessage = (status == .failed ? turn.error : nil) ?? assistantText

            var title = HermesSQL.text(row["title"]).map(Self.singleLine) ?? ""
            if title.isEmpty, let first = try messages.firstUserText(sessionID: id) { title = Self.singleLine(first) }
            if title.isEmpty { title = ownCwd == nil || projectName.isEmpty ? "Hermes 会话" : projectName }

            let task = TaskRecord(
                id: "hermes:\(id)",
                agentId: agentId,
                source: .hermes,
                title: SessionFormatting.truncate(title, SessionFormatting.titleLimit),
                projectPath: cwd,
                projectName: projectName,
                status: status,
                lastMessage: lastMessage.map { SessionFormatting.truncate($0, SessionFormatting.lastMessageLimit) },
                pendingRequest: nil,
                origin: .desktop,
                // 桌面上正在跑的会话我们没有它的进程：续聊会和它抢同一个会话，中断也发不了信号。
                controllable: status != .running,
                startedAt: ProtocolJSON.timestamp(startedAt),
                updatedAt: ProtocolJSON.timestamp(activityAt))
            tasks.append(task)
            if HermesSQL.text(row["source"]) == "cron", let jobID = Self.cronJobID(sessionID: id) {
                let failed = status == .failed
                // content 可能只是 failed_turn 的统一占位回复，没有真实诊断时不能合并不同运行的故障。
                let fingerprint = failed ? turn.failureFingerprint : nil
                let body = failed ? SessionFormatting.truncate([task.title, lastMessage].compactMap { $0 }.joined(separator: "\n"),
                                                               SessionFormatting.lastMessageLimit) : nil
                notifications[task.id] = ObservedTaskNotification(groupID: databasePath + "\u{0}" + jobID,
                                                                  failureFingerprint: fingerprint, failureBody: body)
            }
        }
        return ObservedSessionSnapshot(tasks: tasks, projects: SessionFormatting.projects(from: tasks, agentId: agentId),
                                       notifications: notifications)
    }

    /// Hermes cron 的每次执行都有新会话：cron_<jobID>_<YYYYMMDD>_<HHMMSS>。从尾部拆，jobID 可以含下划线。
    static func cronJobID(sessionID: String) -> String? {
        guard sessionID.hasPrefix("cron_") else { return nil }
        let parts = sessionID.dropFirst(5).split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let date = parts[parts.count - 2], time = parts[parts.count - 1]
        guard date.count == 8, time.count == 6,
              date.allSatisfy({ $0 >= "0" && $0 <= "9" }), time.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        let jobID = parts.dropLast(2).joined(separator: "_")
        guard !jobID.isEmpty else { return nil }
        let dateDigits = Array(date), timeDigits = Array(time)
        let year = Int(String(dateDigits[0..<4]))!, month = Int(String(dateDigits[4..<6]))!, day = Int(String(dateDigits[6..<8]))!
        let hour = Int(String(timeDigits[0..<2]))!, minute = Int(String(timeDigits[2..<4]))!, second = Int(String(timeDigits[4..<6]))!
        guard year > 0, (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let parsed = calendar.date(from: components) else { return nil }
        let parsedComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)
        guard parsedComponents.year == year, parsedComponents.month == month, parsedComponents.day == day,
              parsedComponents.hour == hour, parsedComponents.minute == minute, parsedComponents.second == second else { return nil }
        return jobID
    }

    /// 状态映射。顺序有讲究：
    /// 1. 超过 24 小时没动一律 idle（含 failed，让旧的红色状态自然淡出，与 Codex 一致）；
    /// 2. `end_reason` 是出错类，或最新 active assistant 标成 `failed_turn` → failed；
    /// 3. 没结束、2 分钟内有动静、且最后一条不是"已收尾的回答" → running；
    /// 4. 其余 completed（包括没写 `ended_at` 但早就不动了的——进程多半已经没了）。
    ///
    /// 第 3 条比 spec 多看了一眼最后一条消息：交互式 `hermes` 在两轮之间会话一直开着（`ended_at` 为空），
    /// `-q` 跑完也未必写 `ended_at`；只看时间的话，每答完一句都会在手机上"正在运行"两分钟。
    /// 老库没有 `finish_reason` 列时 `turnFinished` 恒为 false，退回纯时间判断。
    public static func status(endReason: String?, ended: Bool, activityAt: Date, now: Date,
                              turnFinished: Bool = false, turnFailed: Bool = false) -> TaskStatus {
        if now.timeIntervalSince(activityAt) > SessionFormatting.idleAfter { return .idle }
        if let endReason, failedEndReasons.contains(endReason) { return .failed }
        if turnFailed { return .failed }
        if !ended, now.timeIntervalSince(activityAt) <= runningWindow, !turnFinished { return .running }
        return .completed
    }

    // MARK: - 查找

    /// 一个会话的工作目录。连接器续聊时要把子进程放回原项目里（`--in` 与 `currentDirectoryURL`）。
    /// 会话在、但没有 cwd（桌面端等）回 `fallbackDirectory`，与快照里给的项目路径一致；
    /// 库不在、会话不在返回 nil，由连接器退回自己记得的目录。
    public func cwd(forSession sessionID: String) -> String? {
        guard FileManager.default.fileExists(atPath: databasePath),
              let database = try? SQLiteDatabase(path: databasePath),
              let columns = try? HermesSQL.columns(of: "sessions", in: database), columns.contains("id") else { return nil }
        let selected = columns.contains("cwd") ? "cwd" : "id"
        guard let row = try? database.query("SELECT \(selected) FROM sessions WHERE id = ? LIMIT 1",
                                            [.text(sessionID)]).first else { return nil }
        return HermesSQL.directory(row["cwd"]) ?? fallbackDirectory
    }

    /// 标题必须单行：换行与连续空白压成一个空格。
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// `SessionObserver` 的 Hermes 数据源。每轮现建一个 reader，路径设置改了下一轮就生效。
public struct HermesStateSource: SessionSnapshotSource {
    public let paths: HermesPaths
    private let now: @Sendable () -> Date

    public init(paths: HermesPaths = HermesPaths(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.now = now
    }

    public func readSnapshot(agentId: String) throws -> (tasks: [TaskRecord], projects: [Project]) {
        try HermesStateReader(paths: paths, now: now).readSnapshot(agentId: agentId)
    }

    public func readObservedSnapshot(agentId: String) throws -> ObservedSessionSnapshot {
        try HermesStateReader(paths: paths, now: now).readObservedSnapshot(agentId: agentId)
    }
}

/// state.db 的结构不是我们认得的样子（缺表、缺关键列）。观察者按普通失败计数，连续 3 次才报。
public struct HermesSchemaError: LocalizedError, Hashable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - 共用的 SQL 小工具（观察者与消息读取器都用）

enum HermesSQL {
    /// 多模态内容的存法：`"\u{0}json:" + JSON`。前缀带 NUL，所以读 `content` 时一律 `CAST(… AS BLOB)`——
    /// `SQLiteDatabase` 取 TEXT 用的是 `String(cString:)`，遇到第一个 NUL 就截断，整条内容会变成空串。
    static let jsonPrefix = "\u{0}json:"

    /// `PRAGMA table_info` 的列名集合；表不存在时是空集。
    static func columns(of table: String, in database: SQLiteDatabase) throws -> Set<String> {
        Set(try database.query("PRAGMA table_info(\(table))").compactMap { $0["name"]?.string })
    }

    /// TEXT 与 BLOB（`CAST AS BLOB` 读出来的）都当 UTF-8 文本。
    static func text(_ value: SQLiteValue?) -> String? {
        switch value {
        case .text(let text): return text
        case .blob(let data): return String(decoding: data, as: UTF8.self)
        case .integer(let number): return String(number)
        default: return nil
        }
    }

    /// `sessions.cwd`：去掉首尾空白，空的当没有。
    static func directory(_ value: SQLiteValue?) -> String? {
        guard let cwd = text(value)?.trimmed, !cwd.isEmpty else { return nil }
        return cwd
    }

    /// Hermes 的时间是 REAL epoch 秒；老数据或手工写入的也可能是整数或数字字符串。
    static func seconds(_ value: SQLiteValue?) -> Double? {
        switch value {
        case .real(let number): return number
        case .integer(let number): return Double(number)
        case .text(let text): return Double(text)
        default: return nil
        }
    }

    /// `messages.content` → 可读文本。带 `\0json:` 前缀的是 OpenAI 形状的内容块（`[{type:"text",text}, {type:"image_url",…}]`），
    /// 只拼文本块；图片等一律跳过。解析不了的 JSON 返回 nil，不把一坨原文塞进对话。
    static func decodeContent(_ raw: String?) -> String? {
        parseContent(raw).flatMap(text(inContent:))
    }

    /// `messages.content` 解析一次：普通文本原样（String），`\0json:` 的解出 JSON 对象，坏 JSON 返回 nil。
    /// 对话记录要同时取文字和图片，先解析再分别用 `text(inContent:)` / `images(inContent:)`，不重复解析。
    static func parseContent(_ raw: String?) -> Any? {
        guard let raw else { return nil }
        guard raw.hasPrefix(jsonPrefix) else { return raw }
        let json = raw.dropFirst(jsonPrefix.count)
        return try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }

    /// 内容块里的图片：`{type:"image_url", image_url:{url:"data:…"}}`，也认 `image_url` 直接是字符串的写法
    /// （Responses API 的 `input_image` 就是这样）。只收 data URL——http 地址的图不在本机，拿不到字节。
    static func images(inContent object: Any) -> [ImageSource] {
        guard let parts = object as? [Any] else { return [] }
        return parts.compactMap { part -> ImageSource? in
            guard let block = part as? [String: Any],
                  let type = block["type"] as? String, type == "image_url" || type == "input_image" else { return nil }
            let url = (block["image_url"] as? [String: Any])?["url"] ?? block["image_url"]
            return (url as? String).flatMap(ImageSource.init(dataURL:))
        }
    }

    static func text(inContent object: Any) -> String? {
        if let text = object as? String { return text }
        if let parts = object as? [Any] {
            let texts = parts.compactMap { part -> String? in
                if let text = part as? String { return text }
                guard let block = part as? [String: Any] else { return nil }
                let type = block["type"] as? String
                guard type == nil || type == "text" || type == "input_text" || type == "output_text" else { return nil }
                return block["text"] as? String
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        if let block = object as? [String: Any] {
            if let text = block["text"] as? String { return text }
            if let content = block["content"] { return text(inContent: content) }
        }
        return nil
    }
}

/// 观察者对 `messages` 表的小查询。列同样先探测：老库没有 `active` / `timestamp` / `finish_reason` / `display_kind` 时照样能读。
struct HermesMessageQueries {
    private let database: SQLiteDatabase
    private let columns: Set<String>

    init(database: SQLiteDatabase) throws {
        self.database = database
        self.columns = try HermesSQL.columns(of: "messages", in: database)
    }

    private var usable: Bool { columns.isSuperset(of: ["session_id", "role", "content"]) }
    /// 只看当前对话里的消息（`active=1`）；回退/改写掉的分支不算。
    private var activeFilter: String { columns.contains("active") ? " AND COALESCE(active, 1) = 1" : "" }
    private var newestFirst: String { columns.contains("timestamp") ? "timestamp DESC, id DESC" : "id DESC" }
    private var oldestFirst: String { columns.contains("timestamp") ? "timestamp ASC, id ASC" : "id ASC" }

    /// 首条非空的 user 文本，做标题的兜底。多取几条是因为头几条可能是纯图片、解出来是空的。
    func firstUserText(sessionID: String) throws -> String? {
        guard usable else { return nil }
        let rows = try database.query("""
            SELECT CAST(content AS BLOB) AS content FROM messages
            WHERE session_id = ? AND role = 'user'\(activeFilter)
            ORDER BY \(oldestFirst) LIMIT 5
            """, [.text(sessionID)])
        return firstNonEmpty(rows)
    }

    /// 最后一条非空的 assistant 文本（lastMessage）。只拿 `content`：`reasoning*` 列是模型的内部思考，不外发。
    func lastAssistantText(sessionID: String) throws -> String? {
        guard usable else { return nil }
        let rows = try database.query("""
            SELECT CAST(content AS BLOB) AS content FROM messages
            WHERE session_id = ? AND role = 'assistant' AND content IS NOT NULL\(activeFilter)
            ORDER BY \(newestFirst) LIMIT 5
            """, [.text(sessionID)])
        return firstNonEmpty(rows)
    }

    struct TurnState {
        var finished = false
        var failed = false
        var error: String?
        var failureFingerprint: String?
    }

    /// 最新 active 消息代表的轮次状态；只取结构化收尾字段，不从 assistant 正文猜测失败。
    func lastTurnState(sessionID: String) throws -> TurnState {
        guard usable, columns.contains("finish_reason") || columns.contains("display_kind") else { return TurnState() }
        let optional = ["finish_reason", "tool_calls", "display_kind"].filter(columns.contains).map { ", \($0)" }.joined()
        let metadata = columns.contains("display_metadata") ? ", CAST(display_metadata AS BLOB) AS display_metadata" : ""
        guard let row = try database.query("""
            SELECT role\(optional)\(metadata) FROM messages
            WHERE session_id = ?\(activeFilter)
            ORDER BY \(newestFirst) LIMIT 1
            """, [.text(sessionID)]).first,
              HermesSQL.text(row["role"]) == "assistant" else { return TurnState() }
        if HermesSQL.text(row["display_kind"]) == "failed_turn" {
            let metadata = Self.failureMetadata(row["display_metadata"])
            return TurnState(finished: true, failed: true, error: metadata.error, failureFingerprint: metadata.fingerprint)
        }
        guard let reason = HermesSQL.text(row["finish_reason"]),
              HermesStateReader.finishedReasons.contains(reason) else { return TurnState() }
        let pendingTools = HermesSQL.text(row["tool_calls"]).map { !HermesToolCalls.parse($0).isEmpty } ?? false
        return TurnState(finished: !pendingTools)
    }

    private static func failureMetadata(_ value: SQLiteValue?) -> (error: String?, fingerprint: String?) {
        guard let text = HermesSQL.text(value),
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return (nil, nil) }
        let rawError = (object["error"] as? String)?.trimmed
        let error = rawError?.isEmpty == false ? rawError : nil
        var stable: [String: Any] = [:]
        if let surface = object["error_surface"] as? [String: Any] {
            for key in ["layer", "code", "provider", "model"] {
                if let value = (surface[key] as? String)?.trimmed, !value.isEmpty {
                    stable[key] = SessionFormatting.truncate(value, 200)
                }
                else if let value = surface[key] as? NSNumber { stable[key] = value }
            }
        }
        // 只有 provider / model 或 unknown 分类的 surface 没说明故障种类，仍须按真实原错误区分。
        let knownCode = (stable["code"] as? String).map {
            !["unknown", "unknown_error", "unknown-error"].contains($0.lowercased())
        } ?? (stable["code"] != nil)
        if knownCode,
           let data = try? JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return (error, "surface:\(String(decoding: data, as: UTF8.self))")
        }
        return (error, error.map { "error:\(SessionFormatting.truncate($0, SessionFormatting.detailLimit))" })
    }

    private func firstNonEmpty(_ rows: [[String: SQLiteValue]]) -> String? {
        for row in rows {
            if let text = HermesSQL.decodeContent(HermesSQL.text(row["content"]))?.trimmed, !text.isEmpty { return text }
        }
        return nil
    }
}
