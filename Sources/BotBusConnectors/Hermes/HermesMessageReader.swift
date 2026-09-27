import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 从 `~/.hermes/state.db` 的 `messages` 表读一个会话的对话记录。
///
/// 映射：`user` → 用户；`assistant` 的 `content` → agent，它的每个 `tool_calls` 条目各压成一行 `.tool` 摘要；
/// `role='tool'`（工具结果，往往是整个文件或一屏日志）与 `system` 直接跳过。
/// **`reasoning*` 列一律不读**：那是模型的内部思考，与 Codex 那边不收 `reasoning` 是同一条规矩。
///
/// 一行 assistant 可能展开成好几条消息，所以 id 用 `<行 id>`（正文）/ `<行 id>#<n>`（第 n 个工具调用），
/// 重复拉取时保持稳定。
public struct HermesMessageReader: MessageReader {
    public var kind: ConnectorKind { .hermes }

    /// 翻页时每次从库里取多少行（倒序）。一行最多展开出若干条，凑够 `limit + 1` 条对话（工具行不算）就停。
    static let pageSize = 100
    /// 工具摘要里参数部分的上限：手机上一行放不下更多。
    static let argumentLimit = 80

    private let paths: @Sendable () -> HermesPaths

    public init(paths: @escaping @Sendable () -> HermesPaths = { HermesPaths() }) {
        self.paths = paths
    }

    public func entries(taskId: String, limit: Int) async throws -> (entries: [TranscriptEntry], hasMore: Bool) {
        let sessionID = try nativeTaskId(taskId, kind: .hermes)
        guard let url = paths().stateDatabase else { throw ConnectorError("没找到 Hermes 数据库") }
        let database = try SQLiteDatabase(path: url.path)
        let columns = try HermesSQL.columns(of: "messages", in: database)
        guard columns.isSuperset(of: ["id", "session_id", "role", "content"]) else {
            throw ConnectorError("Hermes 数据库的 messages 表结构不认识")
        }

        let optional = ["tool_calls", "timestamp"].filter(columns.contains).map { ", \($0)" }.joined()
        let active = columns.contains("active") ? " AND COALESCE(active, 1) = 1" : ""
        let order = columns.contains("timestamp") ? "timestamp DESC, id DESC" : "id DESC"

        // 倒着翻页：最新的在前，攒够 limit + 1 条对话（多一条只为判断"还有更早的"）就停。
        var newestFirst: [TranscriptEntry] = []
        var offset = 0
        while !TranscriptWindow.isEnough(newestFirst, limit: limit) {
            let rows = try database.query("""
                SELECT id, role, CAST(content AS BLOB) AS content\(optional) FROM messages
                WHERE session_id = ? AND role IN ('user', 'assistant')\(active)
                ORDER BY \(order) LIMIT ? OFFSET ?
                """, [.text(sessionID), .integer(Int64(Self.pageSize)), .integer(Int64(offset))])
            for row in rows { newestFirst += Self.entries(from: row).reversed() }
            if rows.count < Self.pageSize { break }
            offset += rows.count
        }

        return TranscriptWindow.latest(newestFirst.reversed(), limit: limit)
    }

    /// 一行 → 零到多条消息，按时间正序（正文在前，工具调用在后：OpenAI 形状里先说"我去看看"再调工具）。
    static func entries(from row: [String: SQLiteValue]) -> [TranscriptEntry] {
        guard let rowID = HermesSQL.text(row["id"]), let role = HermesSQL.text(row["role"]) else { return [] }
        let createdAt = ProtocolJSON.timestamp(Date(timeIntervalSince1970: HermesSQL.seconds(row["timestamp"]) ?? 0))
        var result: [TranscriptEntry] = []
        // 图片只取 user 的（用户发来的截图）；截断与判空在 `transcriptEntry` 里，纯图片的消息也留着。
        if let content = HermesSQL.parseContent(HermesSQL.text(row["content"])),
           let entry = transcriptEntry(id: rowID, role: role == "user" ? .user : .agent,
                                       text: HermesSQL.text(inContent: content),
                                       images: role == "user" ? HermesSQL.images(inContent: content) : [],
                                       createdAt: createdAt) {
            result.append(entry)
        }
        guard role == "assistant", let json = HermesSQL.text(row["tool_calls"]) else { return result }
        for (index, call) in HermesToolCalls.parse(json).enumerated() {
            if let entry = transcriptEntry(id: "\(rowID)#\(index + 1)", role: .tool,
                                           text: call.summary(argumentLimit: argumentLimit), createdAt: createdAt) {
                result.append(entry)
            }
        }
        return result
    }
}

/// `messages.tool_calls`：OpenAI 形状的 JSON 串 `[{id, type:"function", function:{name, arguments}}]`，
/// 其中 `arguments` 通常又是一个 JSON **字符串**。整段容错：坏 JSON 就是没有工具调用。
struct HermesToolCalls {
    struct Call {
        var name: String
        /// 解开后的参数（通常是字典）；解不开的字符串保留原文。
        var arguments: Any?

        /// `terminal: <命令>`，其余 `<函数名>(<简短参数>)`。
        func summary(argumentLimit: Int) -> String {
            let object = arguments as? [String: Any]
            if name == "terminal", let command = (object?["command"] as? String)?.trimmed, !command.isEmpty {
                return "terminal: \(command)"
            }
            let short = Self.shortArguments(arguments, limit: argumentLimit)
            return short.isEmpty ? "\(name)()" : "\(name)(\(short))"
        }

        /// 最能说明"在干什么"的那个参数优先（路径、查询、网址……），否则把整个参数压成一行 JSON 截断。
        static func shortArguments(_ arguments: Any?, limit: Int) -> String {
            guard let arguments else { return "" }
            if let object = arguments as? [String: Any] {
                for key in ["path", "file_path", "query", "url", "pattern", "command", "name"] {
                    if let value = (object[key] as? String)?.trimmed, !value.isEmpty {
                        return clip(HermesStateReader.singleLine(value), limit)
                    }
                }
                guard !object.isEmpty else { return "" }
            }
            if let text = arguments as? String { return clip(HermesStateReader.singleLine(text), limit) }
            guard JSONSerialization.isValidJSONObject(arguments),
                  let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return "" }
            return clip(String(decoding: data, as: UTF8.self), limit)
        }

        private static func clip(_ text: String, _ limit: Int) -> String {
            text.count <= limit ? text : String(text.prefix(limit)) + "…"
        }
    }

    static func parse(_ json: String) -> [Call] {
        guard let data = json.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            let function = entry["function"] as? [String: Any]
            guard let name = ((function?["name"] ?? entry["name"]) as? String)?.trimmed, !name.isEmpty else { return nil }
            var arguments = function?["arguments"] ?? entry["arguments"]
            if let text = arguments as? String {
                // 字符串形状的参数先试着当 JSON 解开；解不开就保留原文。
                arguments = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? (text.trimmed.isEmpty ? nil : text)
            }
            return Call(name: name, arguments: arguments)
        }
    }
}
