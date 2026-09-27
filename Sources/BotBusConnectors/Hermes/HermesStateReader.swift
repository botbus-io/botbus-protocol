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
    private let now: @Sendable () -> Date

    public init(databasePath: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.databasePath = databasePath
        self.now = now
    }

    /// 不管库在不在都能建；读的时候才判断（`readSnapshot` 抛 `SessionSourceUnavailable`）。
    public init(paths: HermesPaths, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(databasePath: paths.hermesHome.appendingPathComponent("state.db").path, now: now)
    }

    // MARK: - 快照

    /// 7 天内有活动、带 `cwd`、没归档/隐藏、不是被压缩掉的旧会话，活动时间降序，最多 200 条。
    ///
    /// Telegram 等渠道的私聊没有 `cwd`，不进快照——它们不是"某个项目里的编码任务"，也不该未经同意同步到手机。
    /// 库不存在抛 `SessionSourceUnavailable`（观察者据此不对账，一条都不摘）；缺表、忙锁照常抛错，
    /// 由观察者按连续失败次数报警。
    public func readSnapshot(agentId: String) throws -> (tasks: [TaskRecord], projects: [Project]) {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw SessionSourceUnavailable("未找到 Hermes 数据库：\(databasePath)")
        }
        let database = try SQLiteDatabase(path: databasePath)
        let tasks = try readTasks(database: database, agentId: agentId)
        return (tasks, SessionFormatting.projects(from: tasks, agentId: agentId))
    }

    func readTasks(database: SQLiteDatabase, agentId: String) throws -> [TaskRecord] {
        let sessionColumns = try HermesSQL.columns(of: "sessions", in: database)
        guard !sessionColumns.isEmpty else { throw HermesSchemaError("state.db 里没有 sessions 表") }
        guard sessionColumns.contains("id") else { throw HermesSchemaError("sessions 表缺 id 列") }
        // 没有 cwd 列的老库里没有"项目会话"这回事：如实报空，而不是报错。
        guard sessionColumns.contains("cwd") else { return [] }
        let activityParts = ["last_activity_at", "ended_at", "started_at"].filter(sessionColumns.contains)
        guard !activityParts.isEmpty else { throw HermesSchemaError("sessions 表没有任何时间列") }
        let activity = activityParts.count == 1 ? activityParts[0] : "COALESCE(\(activityParts.joined(separator: ", ")))"

        var filters = ["cwd IS NOT NULL", "TRIM(cwd) != ''", "\(activity) > ?"]
        if sessionColumns.contains("archived") { filters.append("COALESCE(archived, 0) = 0") }
        if sessionColumns.contains("hidden") { filters.append("COALESCE(hidden, 0) = 0") }
        // 压缩会以 end_reason='compression' 结束旧会话、新开一行接着聊：只显示链条末端。
        if sessionColumns.contains("end_reason") { filters.append("(end_reason IS NULL OR end_reason != 'compression')") }

        let wanted = ["id", "cwd", "title", "started_at", "ended_at", "last_activity_at", "end_reason"]
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
        for row in rows {
            guard let id = HermesSQL.text(row["id"]), !id.isEmpty,
                  let cwd = HermesSQL.text(row["cwd"])?.trimmed, !cwd.isEmpty,
                  let activitySeconds = HermesSQL.seconds(row["activity_at"]) else { continue }
            let activityAt = Date(timeIntervalSince1970: activitySeconds)
            let startedAt = HermesSQL.seconds(row["started_at"]).map(Date.init(timeIntervalSince1970:)) ?? activityAt
            let endedAt = HermesSQL.seconds(row["ended_at"])
            let endReason = HermesSQL.text(row["end_reason"])
            let projectName = SessionFormatting.projectName(cwd)

            // 只有"看上去还在跑"的才去问最后一条消息：它决定 running 与 completed 的分界，其余状态用不上。
            let looksRunning = endedAt == nil && current.timeIntervalSince(activityAt) <= Self.runningWindow
            let turnFinished = looksRunning ? try messages.lastTurnFinished(sessionID: id) : false
            let status = Self.status(endReason: endReason, ended: endedAt != nil, activityAt: activityAt,
                                     now: current, turnFinished: turnFinished)

            var title = HermesSQL.text(row["title"]).map(Self.singleLine) ?? ""
            if title.isEmpty, let first = try messages.firstUserText(sessionID: id) { title = Self.singleLine(first) }
            if title.isEmpty { title = projectName.isEmpty ? "Hermes 会话" : projectName }

            tasks.append(TaskRecord(
                id: "hermes:\(id)",
                agentId: agentId,
                source: .hermes,
                title: SessionFormatting.truncate(title, SessionFormatting.titleLimit),
                projectPath: cwd,
                projectName: projectName,
                status: status,
                lastMessage: try messages.lastAssistantText(sessionID: id)
                    .map { SessionFormatting.truncate($0, SessionFormatting.lastMessageLimit) },
                pendingRequest: nil,
                origin: .desktop,
                // 桌面上正在跑的会话我们没有它的进程：续聊会和它抢同一个会话，中断也发不了信号。
                controllable: status != .running,
                startedAt: ProtocolJSON.timestamp(startedAt),
                updatedAt: ProtocolJSON.timestamp(activityAt)))
        }
        return tasks
    }

    /// 状态映射。顺序有讲究：
    /// 1. 超过 24 小时没动一律 idle（含 failed，让旧的红色状态自然淡出，与 Codex 一致）；
    /// 2. `end_reason` 是出错类 → failed；
    /// 3. 没结束、2 分钟内有动静、且最后一条不是"已收尾的回答" → running；
    /// 4. 其余 completed（包括没写 `ended_at` 但早就不动了的——进程多半已经没了）。
    ///
    /// 第 3 条比 spec 多看了一眼最后一条消息：交互式 `hermes` 在两轮之间会话一直开着（`ended_at` 为空），
    /// `-q` 跑完也未必写 `ended_at`；只看时间的话，每答完一句都会在手机上"正在运行"两分钟。
    /// 老库没有 `finish_reason` 列时 `turnFinished` 恒为 false，退回纯时间判断。
    public static func status(endReason: String?, ended: Bool, activityAt: Date, now: Date,
                              turnFinished: Bool = false) -> TaskStatus {
        if now.timeIntervalSince(activityAt) > SessionFormatting.idleAfter { return .idle }
        if let endReason, failedEndReasons.contains(endReason) { return .failed }
        if !ended, now.timeIntervalSince(activityAt) <= runningWindow, !turnFinished { return .running }
        return .completed
    }

    // MARK: - 查找

    /// 一个会话的工作目录。连接器续聊时要把子进程放回原项目里（`--in` 与 `currentDirectoryURL`）。
    /// 库不在、会话不在、没有 cwd 都返回 nil，由连接器退回自己记得的目录。
    public func cwd(forSession sessionID: String) -> String? {
        guard FileManager.default.fileExists(atPath: databasePath),
              let database = try? SQLiteDatabase(path: databasePath),
              let columns = try? HermesSQL.columns(of: "sessions", in: database), columns.contains("cwd"),
              let row = try? database.query("SELECT cwd FROM sessions WHERE id = ? LIMIT 1", [.text(sessionID)]).first,
              let cwd = HermesSQL.text(row["cwd"])?.trimmed, !cwd.isEmpty else { return nil }
        return cwd
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

/// 观察者对 `messages` 表的三个小查询。列同样先探测：老库没有 `active` / `timestamp` / `finish_reason` 时照样能读。
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

    /// 最后一条消息是不是"这一轮已经答完"：assistant、`finish_reason` 是收尾类、没有挂着工具调用。
    func lastTurnFinished(sessionID: String) throws -> Bool {
        guard usable, columns.contains("finish_reason") else { return false }
        let toolCalls = columns.contains("tool_calls") ? ", tool_calls" : ""
        guard let row = try database.query("""
            SELECT role, finish_reason\(toolCalls) FROM messages
            WHERE session_id = ?\(activeFilter)
            ORDER BY \(newestFirst) LIMIT 1
            """, [.text(sessionID)]).first else { return false }
        guard HermesSQL.text(row["role"]) == "assistant",
              let reason = HermesSQL.text(row["finish_reason"]),
              HermesStateReader.finishedReasons.contains(reason) else { return false }
        let pendingTools = HermesSQL.text(row["tool_calls"]).map { !HermesToolCalls.parse($0).isEmpty } ?? false
        return !pendingTools
    }

    private func firstNonEmpty(_ rows: [[String: SQLiteValue]]) -> String? {
        for row in rows {
            if let text = HermesSQL.decodeContent(HermesSQL.text(row["content"]))?.trimmed, !text.isEmpty { return text }
        }
        return nil
    }
}
