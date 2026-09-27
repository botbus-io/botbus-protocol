import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 读 OpenClaw 会话的对话记录：经 Gateway 的 `chat.history {sessionKey, limit}`。
///
/// OpenClaw 的 transcript 在 Gateway 自己的 SQLite 里（部分行 zstd 压缩），没有能直接读的文件，
/// 所以"独立于连接器"在这里的含义是：**不要求连接器在跑**。默认实现每次拉取自己开一条 Gateway 连接、
/// 握手、取完就关；app 也可以用 `preferring(connector:)` 先借连接器那条已连上的连接，借不到再自己连。
///
/// 消息形状与 Pi 相同（`packages/llm-core/src/types.ts`）：`role` 为 `user` / `assistant` / `toolResult`，
/// assistant 的 `content` 是 `text` / `thinking` / `toolCall` 块。映射：user 的文字与图片 → `.user`；assistant 的文本 → `.agent`
/// （thinking 不进对话，同 Codex 的 reasoning）；toolCall → 一行 `.tool` 摘要；toolResult 跳过。
public struct OpenClawMessageReader: MessageReader {
    public var kind: ConnectorKind { .openclaw }

    /// 取一页 `chat.history` 的原始 payload。
    public typealias Fetch = @Sendable (_ sessionKey: String, _ limit: Int) async throws -> JSONValue

    private let fetch: Fetch

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// 每次拉取单独连一次 Gateway。
    public init(config: @escaping @Sendable () -> OpenClawConfig = { OpenClawConfig.load() },
                transport: WebSocketTransport = OpenClawWebSocketTransport(),
                clientVersion: String = OpenClawGateway.defaultClientVersion) {
        self.fetch = { sessionKey, limit in
            try await Self.fetchOnce(sessionKey: sessionKey, limit: limit, config: config(),
                                     transport: transport, clientVersion: clientVersion)
        }
    }

    /// 先用连接器那条连接；它没连上（或已停）再自己连一次。
    public static func preferring(connector: OpenClawConnector,
                                  config: @escaping @Sendable () -> OpenClawConfig = { OpenClawConfig.load() },
                                  transport: WebSocketTransport = OpenClawWebSocketTransport(),
                                  clientVersion: String = OpenClawGateway.defaultClientVersion) -> OpenClawMessageReader {
        OpenClawMessageReader { sessionKey, limit in
            if await connector.isConnected {
                return try await connector.chatHistory(sessionKey: sessionKey, limit: limit)
            }
            return try await fetchOnce(sessionKey: sessionKey, limit: limit, config: config(),
                                       transport: transport, clientVersion: clientVersion)
        }
    }

    static func fetchOnce(sessionKey: String, limit: Int, config: OpenClawConfig,
                          transport: WebSocketTransport, clientVersion: String) async throws -> JSONValue {
        let gateway = OpenClawGateway(transport: transport,
                                      configuration: .init(config: config, clientVersion: clientVersion))
        do {
            try await gateway.connect()
            let payload = try await gateway.request("chat.history",
                                                    params: ["sessionKey": .string(sessionKey), "limit": .int(Int64(limit))])
            await gateway.close()
            return payload
        } catch {
            await gateway.close()
            throw error
        }
    }

    public func entries(taskId: String, limit: Int) async throws -> (entries: [TranscriptEntry], hasMore: Bool) {
        let sessionKey = try nativeTaskId(taskId, kind: .openclaw)
        let payload = try await fetch(sessionKey, Self.recordLimit(forConversation: limit))
        let all = Self.entries(from: payload)
        // 一条 transcript 记录可能展开成好几条（文本 + 工具调用），也可能整条被跳过，所以两边都要看。
        let (window, hasMore) = TranscriptWindow.latest(all, limit: limit)
        return (window, hasMore || payload["hasMore"]?.boolValue == true)
    }

    /// `chat.history` 的 `limit` 数的是存储记录，工具调用与工具结果各占一条，而窗口只数对话：
    /// 按每条对话平均夹几次工具调用往多了要，凑不够就少几条，不为此多拉一次。
    static func recordLimit(forConversation limit: Int) -> Int {
        (min(max(limit, 1), TaskMessages.maxMessages) + 1) * 8
    }

    /// 整页映射，按 Gateway 给的顺序（旧 → 新）。id 在同一页里去重：一条存储记录可能投影成多行、共用 `__openclaw.id`。
    static func entries(from payload: JSONValue) -> [TranscriptEntry] {
        let records = payload.arrayValue ?? payload["messages"]?.arrayValue ?? []
        var used: [String: Int] = [:]
        var result: [TranscriptEntry] = []
        for record in records {
            for var entry in entries(fromRecord: record) {
                let count = used[entry.message.id, default: 0]
                used[entry.message.id] = count + 1
                if count > 0 { entry.message.id += "~\(count)" }
                result.append(entry)
            }
        }
        return result
    }

    /// 一条 transcript 记录 → 0…n 条。
    static func entries(fromRecord entry: JSONValue) -> [TranscriptEntry] {
        guard entry.objectValue != nil else { return [] }
        let meta = entry["__openclaw"]
        // 压缩边界、重置边界这类合成行没有对话内容。
        if meta?["kind"]?.stringValue != nil { return [] }
        let role = entry["role"]?.stringValue
        let timestamp = OpenClawTranscript.date(entry["timestamp"])
        let createdAt = ProtocolJSON.timestamp(timestamp ?? Date(timeIntervalSince1970: 0))
        // 稳定 id：transcript 条目 id 优先，其次序号；都没有就用角色 + 时间戳（重复拉取时不会变）。
        let sequenceID = meta?["seq"]?.intValue.map { "seq-\($0)" }
        let fallbackMillis = timestamp.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
        let fallbackID = "\(role ?? "entry")-\(fallbackMillis)"
        let base = meta?["id"]?.stringValue ?? sequenceID ?? entry["id"]?.stringValue ?? fallbackID

        switch role {
        case "user":
            // 运行期上下文的载体（系统塞进来的环境信息）不是用户说的话。
            if entry["runtimeContextCarrier"]?.boolValue == true { return [] }
            let content = entry["content"]
            return transcriptEntry(id: base, role: .user, text: OpenClawTranscript.text(from: content),
                                   images: OpenClawTranscript.images(from: content), createdAt: createdAt)
                .map { [$0] } ?? []
        case "assistant":
            return assistantEntries(entry["content"], base: base, createdAt: createdAt)
        default:
            // toolResult 的正文往往是整个文件或一屏日志，摘要都嫌长；其余角色（system、bashExecution…）不是对话。
            return []
        }
    }

    /// assistant 的内容块按顺序切：连续的文本并成一条 `.agent`，每个工具调用单独一行 `.tool`。
    private static func assistantEntries(_ content: JSONValue?, base: String, createdAt: String) -> [TranscriptEntry] {
        if let text = content?.stringValue {
            return transcriptEntry(id: base, role: .agent, text: text, createdAt: createdAt).map { [$0] } ?? []
        }
        var entries: [TranscriptEntry] = []
        var buffer: [String] = []
        func append(_ role: Message.Role, _ text: String) {
            let id = entries.isEmpty ? base : "\(base)#\(entries.count)"
            if let entry = transcriptEntry(id: id, role: role, text: text, createdAt: createdAt) { entries.append(entry) }
        }
        func flush() {
            let text = buffer.joined(separator: "\n")
            buffer.removeAll()
            append(.agent, text)
        }
        for block in content?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue { buffer.append(text) }
            case "toolCall", "tool_use":
                flush()
                append(.tool, OpenClawTranscript.toolSummary(block))
            default:
                // thinking 不进对话；assistant 里的图多是工具截图，本期也不收。
                continue
            }
        }
        flush()
        return entries
    }
}

/// 连接器与读取器共用的 transcript 小工具。
enum OpenClawTranscript {
    /// 消息正文：字符串原样；块数组只取 `text` 块拼起来；`{content: …}` 形状的消息对象往里取一层。
    static func text(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue { return text }
        if let blocks = value.arrayValue {
            let texts = blocks.compactMap { block -> String? in
                if let text = block.stringValue { return text }
                guard block["type"]?.stringValue == "text" else { return nil }
                return block["text"]?.stringValue
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        if value.objectValue != nil {
            if let content = value["content"] { return text(from: content) }
            return value["text"]?.stringValue
        }
        return nil
    }

    /// user 消息里的图片块 `{type:"image", data:<base64>, mimeType}`（形状与 Pi 相同，未在真实数据上验证）。
    /// 解不出或不是 `image/*` 的直接跳过，不占位。
    static func images(from value: JSONValue?) -> [ImageSource] {
        (value?.arrayValue ?? []).compactMap { block in
            guard block["type"]?.stringValue == "image",
                  let data = block["data"]?.stringValue, let mimeType = block["mimeType"]?.stringValue else { return nil }
            return ImageSource(base64: data, contentType: mimeType)
        }
    }

    /// 工具调用的一行摘要。shell 类工具把命令本身亮出来，其余只报工具名（参数常常是整段文件内容）。
    static func toolSummary(_ block: JSONValue) -> String {
        let name = block["name"]?.stringValue ?? "工具"
        var arguments = block["arguments"] ?? block["input"]
        // 有的提供方把参数存成 JSON 字符串。
        if let raw = arguments?.stringValue, let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) {
            arguments = decoded
        }
        if let command = arguments?["command"]?.stringValue ?? arguments?["cmd"]?.stringValue, !command.trimmed.isEmpty {
            return "$ \(command.trimmed)"
        }
        if let path = ["path", "file_path", "filePath"].lazy.compactMap({ arguments?[$0]?.stringValue }).first(where: { !$0.isEmpty }) {
            return "调用 \(name)：\((path as NSString).lastPathComponent)"
        }
        return "调用 \(name)"
    }

    /// 毫秒时间戳（Gateway 一律用毫秒）；也接受 ISO 8601 字符串。
    static func date(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if let milliseconds = value.doubleValue, milliseconds > 0 {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        if let text = value.stringValue {
            if let date = try? Date(text, strategy: .iso8601) { return date }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text)
        }
        return nil
    }
}
