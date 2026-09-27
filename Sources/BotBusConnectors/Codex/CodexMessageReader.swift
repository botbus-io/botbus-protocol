import Foundation
import os
import BotBusProtocol
import BotBusConnectorKit

// MARK: - Codex

/// 从 `~/.codex/thread_history_*.sqlite` 的 `thread_items` 读。
///
/// **`reasoning` 不进对话记录**：它是模型的内部思考，在这台机器上就有 7000 多条，
/// 是所有类型里最多的；混进来会把用户真正想看的一问一答挤没。
public struct CodexMessageReader: MessageReader {
    public var kind: ConnectorKind { .codex }

    /// 进对话记录的 item 类型。顺序无关，SQL 里按 rollout 排。
    ///
    /// `imageGeneration` 是模型画的图，算 agent 的回复；`imageView` 与 MCP 结果里的图是工具截图，不收。
    static let includedTypes = ["userMessage", "agentMessage", "imageGeneration",
                                "commandExecution", "fileChange", "mcpToolCall", "webSearch"]

    private let paths: @Sendable () -> CodexPaths

    public init(paths: @escaping @Sendable () -> CodexPaths = { CodexPaths() }) {
        self.paths = paths
    }

    public func entries(taskId: String, limit: Int) async throws -> (entries: [TranscriptEntry], hasMore: Bool) {
        let threadId = try nativeTaskId(taskId, kind: .codex)
        guard let history = paths().historyDatabase else { throw ConnectorError("没找到 Codex 历史库") }
        let database = try SQLiteDatabase(path: history.path)
        let placeholders = Self.includedTypes.map { _ in "?" }.joined(separator: ",")
        // 倒着翻页：工具行不占对话名额，事先不知道要取多少行；攒到对话条数超过 limit
        // （多一条只为判断"还有更早的"）就停，窗口交给 `TranscriptWindow`。
        var newestFirst: [TranscriptEntry] = []
        var offset = 0
        while !TranscriptWindow.isEnough(newestFirst, limit: limit) {
            let rows = try database.query("""
                SELECT item_id, item_type, item_json, created_at_ms FROM thread_items
                WHERE thread_id = ? AND item_type IN (\(placeholders))
                ORDER BY rollout_ordinal DESC, updated_at_ordinal DESC LIMIT ? OFFSET ?
                """, [.text(threadId)] + Self.includedTypes.map { .text($0) }
                    + [.integer(Int64(Self.pageSize)), .integer(Int64(offset))])
            newestFirst += rows.compactMap { Self.entry(from: $0) }
            if rows.count < Self.pageSize { break }
            offset += rows.count
        }
        // SQL 取的是"最近 N 条"（倒序），界面要的是从旧到新，所以这里翻回来。
        return TranscriptWindow.latest(newestFirst.reversed(), limit: limit)
    }

    /// 翻页时每次从库里取多少行（倒序）。
    static let pageSize = 200

    static func entry(from row: [String: SQLiteValue]) -> TranscriptEntry? {
        guard let id = row["item_id"]?.string, let type = row["item_type"]?.string else { return nil }
        let content = content(ofType: type, json: row["item_json"]?.string)
        let createdMs = row["created_at_ms"]?.int ?? 0
        let role: Message.Role = switch type {
        case "userMessage": .user
        case "agentMessage", "imageGeneration": .agent
        default: .tool
        }
        return transcriptEntry(id: id, role: role, text: content.text, images: content.images,
                               createdAt: ProtocolJSON.timestamp(Date(timeIntervalSince1970: Double(createdMs) / 1000)))
    }

    /// 各类型的正文与图片所在，一次解析同时取出。工具类只留一行摘要——手机上没人要看 diff 全文。
    static func content(ofType type: String, json: String?) -> (text: String?, images: [ImageSource]) {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, []) }
        switch type {
        case "userMessage":
            // content 是 [{type, text, …}]，文本块拼起来；`localImage {path}` 与 `image {url: data:…}` 收成图片。
            if let text = object["content"] as? String { return (text, []) }
            guard let blocks = object["content"] as? [[String: Any]] else { return (nil, []) }
            var texts: [String] = []
            var images: [ImageSource] = []
            for block in blocks {
                switch block["type"] as? String {
                case "localImage":
                    if let image = (block["path"] as? String).flatMap(Self.localFile) { images.append(image) }
                case "image":
                    if let image = (block["url"] as? String).flatMap(ImageSource.init(dataURL:)) { images.append(image) }
                default:
                    if let text = block["text"] as? String { texts.append(text) }
                }
            }
            return (texts.joined(separator: "\n"), images)
        case "imageGeneration":
            // 落盘的文件优先：`result` 是整张 PNG 的 base64，能不搬就不搬；没落盘才用它。
            // 文件被用户删了（`savedPath` 还在库里）也退回 `result`，不然这张图就再也看不到了。
            // 改写后的提示词当正文，让手机上看得出这张图是按什么画的。
            let prompt = object["revisedPrompt"] as? String
            let saved = (object["savedPath"] as? String).flatMap(Self.localFile)
            if let saved, case .file(let url) = saved, FileManager.default.fileExists(atPath: url.path) {
                return (prompt, [saved])
            }
            if let inline = (object["result"] as? String).flatMap({ ImageSource(base64: $0, contentType: "image/png") }) {
                return (prompt, [inline])
            }
            // 两样都不可用时仍报文件：读不到由上传器跳过，读取器不替它判断。
            return (prompt, saved.map { [$0] } ?? [])
        default:
            return (text(ofType: type, object: object), [])
        }
    }

    /// 本机图片路径。`~` 开头的展开成 home（Codex 的 `savedPath` 两种写法都有）；
    /// 相对路径不收——拼到 Agent 自己的工作目录上只会指错文件。
    static func localFile(_ path: String) -> ImageSource? {
        let expanded = (path.trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return .file(URL(fileURLWithPath: expanded))
    }

    private static func text(ofType type: String, object: [String: Any]) -> String? {
        switch type {
        case "agentMessage":
            return object["text"] as? String
        case "commandExecution":
            guard let command = object["command"] as? String else { return nil }
            let exit = object["exitCode"] as? Int
            return exit == nil || exit == 0 ? "$ \(command)" : "$ \(command)（退出码 \(exit!)）"
        case "fileChange":
            guard let changes = object["changes"] as? [[String: Any]] else { return nil }
            let paths = changes.compactMap { $0["path"] as? String }.map { ($0 as NSString).lastPathComponent }
            guard !paths.isEmpty else { return nil }
            return "改动 " + paths.prefix(5).joined(separator: "、") + (paths.count > 5 ? " 等 \(paths.count) 个文件" : "")
        case "mcpToolCall":
            let server = object["server"] as? String ?? "mcp"
            guard let tool = object["tool"] as? String else { return nil }
            return "调用 \(server)/\(tool)"
        case "webSearch":
            guard let query = object["query"] as? String else { return nil }
            return "搜索「\(query)」"
        default:
            return nil
        }
    }
}
