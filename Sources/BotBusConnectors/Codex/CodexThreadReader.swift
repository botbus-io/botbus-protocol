import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 只读地把 Codex 的两个 SQLite 映射成协议模型。每次调用重新打开库（轮询间隔 2 秒，开销可忽略，且避免长期持有 WAL 读锁）。
public struct CodexThreadReader {
    public static let maxTasks = 200
    public static let activityWindow: TimeInterval = 7 * 24 * 3600
    public static let idleAfter: TimeInterval = 24 * 3600
    public static let titleLimit = 80
    public static let messageLimit = 500

    public let stateDatabasePath: String
    public let historyDatabasePath: String
    private let now: () -> Date

    /// 两个库任一找不到返回 nil，调用方据此显示"未找到 Codex 数据库"。
    public init?(paths: CodexPaths, now: @escaping () -> Date = Date.init) {
        guard let state = paths.stateDatabase, let history = paths.historyDatabase else { return nil }
        stateDatabasePath = state.path
        historyDatabasePath = history.path
        self.now = now
    }

    /// 最近 7 天、未归档、非 subagent 的线程，按 updated_at_ms 降序，最多 200 条。
    /// 任一库缺表（schema 漂移）或忙锁都抛错让整次轮询失败，由调用方按连续失败次数报警。
    ///
    /// `agentId` 由调用方注入（协议 v2 的归属字段）：reader 只读 SQLite，不该为了知道"我是谁"去依赖凭据。
    public func readTasks(agentId: String) throws -> [TaskRecord] {
        let state = try SQLiteDatabase(path: stateDatabasePath)
        let history = try SQLiteDatabase(path: historyDatabasePath)
        let current = now()
        let sinceMs = Int64((current.timeIntervalSince1970 - Self.activityWindow) * 1000)
        let rows = try state.query("""
            SELECT id, cwd, name, title, first_user_message, created_at_ms, updated_at_ms, model, reasoning_effort
            FROM threads
            WHERE archived = 0 AND source NOT LIKE '{%' AND updated_at_ms > ?
            ORDER BY updated_at_ms DESC
            LIMIT ?
            """, [.integer(sinceMs), .integer(Int64(Self.maxTasks))])

        var tasks: [TaskRecord] = []
        for row in rows {
            guard let id = row["id"]?.string, let cwd = row["cwd"]?.string,
                  let updatedMs = row["updated_at_ms"]?.int else { continue }
            let createdMs = row["created_at_ms"]?.int ?? updatedMs
            let updatedAt = Date(timeIntervalSince1970: Double(updatedMs) / 1000)

            // 这两条用 try 而不是 try?：history 库缺表或忙锁时吞掉错误，会把所有任务静默显示成 idle、没有最后消息。
            let latestTurn = try history.query(
                "SELECT status FROM thread_turns WHERE thread_id = ? ORDER BY rollout_ordinal DESC LIMIT 1",
                [.text(id)]).first
            let lastItem = try history.query(
                """
                SELECT item_json FROM thread_items
                WHERE thread_id = ? AND item_type = 'agentMessage'
                ORDER BY rollout_ordinal DESC, updated_at_ordinal DESC LIMIT 1
                """, [.text(id)]).first

            let status = Self.status(turnStatus: latestTurn?["status"]?.string, updatedAt: updatedAt, now: current)
            let rawTitle = [row["name"]?.string, row["title"]?.string, row["first_user_message"]?.string]
                .compactMap { $0.map(Self.singleLine) }
                .first { !$0.isEmpty }
            let projectName = URL(fileURLWithPath: cwd).lastPathComponent

            tasks.append(TaskRecord(
                id: "codex:\(id)",
                agentId: agentId,
                source: .codex,
                title: Self.truncate(rawTitle ?? projectName, limit: Self.titleLimit),
                projectPath: cwd,
                projectName: projectName,
                status: status,
                lastMessage: Self.agentMessageText(from: lastItem?["item_json"]?.string)
                    .map { Self.truncate($0, limit: Self.messageLimit) },
                pendingRequest: nil,
                origin: .desktop,
                controllable: status != .running,
                startedAt: ProtocolJSON.timestamp(Date(timeIntervalSince1970: Double(createdMs) / 1000)),
                updatedAt: ProtocolJSON.timestamp(updatedAt),
                // 协议 3.2：线程上记着的模型与强度（桌面上最后一次选的），不合法的值不报——对端会拒收整条。
                model: row["model"]?.string.flatMap { ModelOption.isValidId($0) ? $0 : nil },
                effort: row["reasoning_effort"]?.string.flatMap { ModelOption.isValidEffort($0) ? $0 : nil }))
        }
        return tasks
    }

    /// 最近项目：projects 表按更新时间降序，取每个项目 position=0 的根目录，最多 30 个。
    /// `agentId` 同样由调用方注入——项目路径只在它所属的那台电脑上有意义。
    public func readProjects(agentId: String) throws -> [Project] {
        let state = try SQLiteDatabase(path: stateDatabasePath)
        let rows = try state.query("""
            SELECT p.name AS name, r.path AS path, p.updated_at_ms AS updated_at_ms
            FROM projects p
            JOIN project_roots r ON r.project_id = p.id AND r.position = 0
            ORDER BY p.updated_at_ms DESC
            LIMIT 30
            """)
        return rows.compactMap { row -> Project? in
            guard let path = row["path"]?.string, let ms = row["updated_at_ms"]?.int else { return nil }
            let name = row["name"]?.string ?? URL(fileURLWithPath: path).lastPathComponent
            return Project(agentId: agentId, path: path, name: name,
                           lastUsedAt: ProtocolJSON.timestamp(Date(timeIntervalSince1970: Double(ms) / 1000)),
                           pinned: false)
        }
    }

    /// thread_turns.status ∈ completed | interrupted | failed | inProgress。
    /// 超过 24 小时没动的一律 idle（含 failed / interrupted，让旧的红色状态自然淡出）；
    /// 完全没有轮次记录的线程也是 idle（还没跑过，不能算完成）。public 是为了让测试模块直接测映射表。
    public static func status(turnStatus: String?, updatedAt: Date, now: Date) -> TaskStatus {
        if now.timeIntervalSince(updatedAt) > idleAfter { return .idle }
        switch turnStatus {
        case "inProgress": return .running
        case "failed": return .failed
        case "interrupted": return .interrupted
        case "completed": return .completed
        default: return .idle
        }
    }

    /// 标题必须单行：把换行与连续空白压成一个空格。
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// thread_items.item_json 是 camelCase 的 ThreadItem；坏 JSON 或空文本返回 nil。
    static func agentMessageText(from json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func truncate(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }
}
