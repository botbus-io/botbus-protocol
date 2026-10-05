import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// OpenCode 桌面端与 CLI 共用的数据库。每次打开只读连接，不载入会话、不取得写锁。
public struct OpenCodeSessionReader: MessageReader, Sendable {
    public var kind: ConnectorKind { .acp }
    public let databaseURL: URL

    public init(databaseURL: URL = Self.defaultDatabaseURL) { self.databaseURL = databaseURL }

    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db")
    }

    public static func detectBinary() -> String? {
        AgentBinary.detect("opencode", extra: ["~/.opencode/bin"])
    }

    public static let maxSessions = 200

    public func tasks(now: Date = Date()) throws -> [TaskRecord] {
        try scan(now: now).tasks
    }

    /// 同 `tasks`，另给这一读覆盖到哪：读满 `maxSessions` 条时是最旧那条的时间（比它旧的没读到），没读满是 nil。
    /// 覆盖范围里数据库没有的会话（删了、归档了）就是电脑上没了。
    public func scan(now: Date = Date()) throws -> (tasks: [TaskRecord], coverageStart: Date?) {
        let db = try SQLiteDatabase(path: databaseURL.path)
        let rows = try db.query("""
            SELECT id, directory, title, time_created, time_updated FROM session
            WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated >= ?
            ORDER BY time_updated DESC, id DESC LIMIT ?
            """, [.integer(Int64((now.timeIntervalSince1970 - SessionFormatting.recentWindow) * 1000)),
                  .integer(Int64(Self.maxSessions))])
        let coverageStart = rows.count >= Self.maxSessions ? rows.last.map { Self.date($0["time_updated"]?.int ?? 0) } : nil
        let tasks: [TaskRecord] = try rows.compactMap { row in
            guard let id = row["id"]?.string, let cwd = row["directory"]?.string else { return nil }
            let updated = Self.date(row["time_updated"]?.int ?? 0)
            var task = AcpSessionState.newRecord(connectorId: "opencode", sessionId: id, cwd: cwd,
                                                title: row["title"]?.string, origin: .desktop,
                                                controllable: true, at: ProtocolJSON.timestamp(updated))
            task.startedAt = ProtocolJSON.timestamp(Self.date(row["time_created"]?.int ?? 0))
            task.status = now.timeIntervalSince(updated) > SessionFormatting.idleAfter ? .idle : .completed
            let last = try db.query("SELECT data FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 1", [.text(id)]).first
            if let data = Self.json(last?["data"]?.string), data["role"]?.stringValue == "assistant" {
                if data["error"] != nil {
                    task.status = data["error"]?["name"]?.stringValue == "MessageAbortedError" ? .interrupted : .failed
                } else if data["time"]?["completed"] == nil, now.timeIntervalSince(updated) < 300 {
                    task.status = .running
                }
            } else {
                task.status = .idle
            }
            let recent = try readEntries(db, sessionId: id, limit: 1)
            task.lastMessage = recent.entries.last(where: { $0.message.role != .tool })
                .map { SessionFormatting.truncate($0.message.text, SessionFormatting.lastMessageLimit) }
            return task
        }
        return (tasks, coverageStart)
    }

    public func entries(taskId: String, limit: Int) async throws -> (entries: [TranscriptEntry], hasMore: Bool) {
        guard let parsed = AcpTaskID.parse(taskId), parsed.connectorId == "opencode" else {
            throw ConnectorError("无法识别的 OpenCode 任务")
        }
        return try readEntries(SQLiteDatabase(path: databaseURL.path), sessionId: parsed.sessionId, limit: limit)
    }

    private func readEntries(_ db: SQLiteDatabase, sessionId: String, limit: Int) throws -> (entries: [TranscriptEntry], hasMore: Bool) {
        var newest: [TranscriptEntry] = []
        var offset = 0
        while !TranscriptWindow.isEnough(newest, limit: limit) {
            let messages = try db.query("""
                SELECT id, time_created, data FROM message WHERE session_id = ?
                ORDER BY time_created DESC, id DESC LIMIT 100 OFFSET ?
                """, [.text(sessionId), .integer(Int64(offset))])
            for message in messages {
                guard let id = message["id"]?.string, let data = Self.json(message["data"]?.string),
                      let role = data["role"]?.stringValue, ["user", "assistant"].contains(role) else { continue }
                let timestamp = ProtocolJSON.timestamp(Self.date(message["time_created"]?.int ?? 0))
                let parts = try db.query("SELECT id, data FROM part WHERE message_id = ? ORDER BY id", [.text(id)])
                var text: [String] = []
                var tools: [TranscriptEntry] = []
                var images: [ImageSource] = []
                for part in parts {
                    guard let body = Self.json(part["data"]?.string) else { continue }
                    switch body["type"]?.stringValue {
                    case "text":
                        if body["synthetic"]?.boolValue != true, let value = body["text"]?.stringValue { text.append(value) }
                    case "tool" where role == "assistant":
                        let label = body["state"]?["title"]?.stringValue ?? body["tool"]?.stringValue ?? "tool"
                        if let partId = part["id"]?.string,
                           let entry = transcriptEntry(id: "\(id)#\(partId)", role: .tool, text: label, createdAt: timestamp) {
                            tools.append(entry)
                        }
                    case "file" where role == "user":
                        if let url = body["url"]?.stringValue, let image = ImageSource(dataURL: url) { images.append(image) }
                    default: break // reasoning、步骤、快照、工具结果都不作对话正文。
                    }
                }
                var entries: [TranscriptEntry] = []
                if let entry = transcriptEntry(id: id, role: role == "user" ? .user : .agent,
                                               text: text.joined(separator: "\n"), images: images, createdAt: timestamp) {
                    entries.append(entry)
                }
                entries += tools
                newest += entries.reversed()
            }
            if messages.count < 100 { break }
            offset += messages.count
        }
        return TranscriptWindow.latest(newest.reversed(), limit: limit)
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static func json(_ text: String?) -> JSONValue? {
        text.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }
}
