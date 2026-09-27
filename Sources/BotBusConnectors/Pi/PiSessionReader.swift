import Foundation
import os
import BotBusProtocol
import BotBusConnectorKit

/// 只读地把 Pi 的会话 JSONL（`~/.pi/agent/sessions/*/*.jsonl`）映射成协议模型。
///
/// 文件格式（spec 2026-09-24 的 Pi 一节，**未在真实 pi 上验证**）：
/// - 首行 header：`{"type":"session","version":3,"id":<uuid>,"timestamp":<ISO>,"cwd":"/abs"}`；
/// - 其余每行一条 entry，带 `id` / `parentId`，整份文件是一棵**树**（`/tree` 回到旧节点再说话就分叉）。
///   当前分支 = 最后一条沿 `parentId` 往回走；被丢下的那条分支不算这个会话的现状。
///
/// 解析**全程容错**：坏行、没见过的 entry 类型、字段缺失都只是跳过——多一种新 entry 不该让整个来源读不出来。
/// 首行不是 header 的文件整份跳过：拿不到 cwd，这个任务挂不到任何项目下。
public struct PiSessionReader: Sendable {
    public static let maxTasks = 200
    /// 桌面上跑的会话没有"正在跑"的标记：最后一条还在等模型（user / toolResult / toolUse），
    /// 且文件这么久之内被写过才算 running；更久没动静多半是进程已经没了，算 interrupted。
    public static let runningWindow: TimeInterval = 120

    public let paths: PiPaths
    private let now: @Sendable () -> Date

    public init(paths: PiPaths = PiPaths(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.now = now
    }

    /// 一个会话文件在磁盘上的样子。`size` 与 `modifiedAt` 一起当缓存键（见 `PiSessionSource`）。
    public struct FileInfo: Hashable, Sendable {
        public var url: URL
        public var modifiedAt: Date
        public var size: Int
    }

    // MARK: - 枚举与查找

    /// 7 天内被写过的会话文件，最新的在前，最多 `maxTasks` 个。
    /// 会话目录不存在抛 `SessionSourceUnavailable`——那是"读不到"，不是"没有任务"。
    public func recentFiles() throws -> [FileInfo] {
        let fileManager = FileManager.default
        let root = paths.sessionsDirectory
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SessionSourceUnavailable("未找到 Pi 会话目录：\(root.path)")
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let since = now().addingTimeInterval(-SessionFormatting.recentWindow)
        // 目录名是 cwd 编码出来的（`--Users-me-proj--`），反解不回路径，这里只当成一层分组来扫。
        let directories = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var files: [FileInfo] = []
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { continue }
            for url in entries where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile ?? false,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= since else { continue }
                files.append(FileInfo(url: url, modifiedAt: modifiedAt, size: values.fileSize ?? 0))
            }
        }
        return Array(files.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(Self.maxTasks))
    }

    /// 某个 sessionId 的记录文件。文件名是 `<时间戳>_<sessionId>.jsonl`，所以按后缀在各项目目录里扫；
    /// 连接器续聊（`--session <路径>`）与读对话记录都靠它，不依赖 7 天窗口。
    public func sessionFile(for sessionID: String) -> URL? {
        Self.sessionFile(for: sessionID, in: paths.sessionsDirectory)
    }

    static func sessionFile(for sessionID: String, in sessionsDirectory: URL) -> URL? {
        // 挡住拼路径的花样：sessionId 是 uuid，不该带分隔符。
        guard !sessionID.isEmpty, !sessionID.contains("/") else { return nil }
        let fileManager = FileManager.default
        let suffix = "_\(sessionID).jsonl"
        guard let directories = try? fileManager.contentsOfDirectory(at: sessionsDirectory,
                                                                     includingPropertiesForKeys: nil) else { return nil }
        for directory in directories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            if let name = names.first(where: { $0.hasSuffix(suffix) }) {
                return directory.appendingPathComponent(name)
            }
        }
        return nil
    }

    // MARK: - 映射

    /// 7 天内的会话 → TaskRecord。`summarize` 可注入缓存；默认每次整份重读。
    public func readTasks(agentId: String) throws -> [TaskRecord] {
        try readTasks(agentId: agentId) { Self.summarize(contentsOf: $0.url) }
    }

    func readTasks(agentId: String, summarize: (FileInfo) -> PiSessionSummary?) throws -> [TaskRecord] {
        try recentFiles().compactMap { file in
            summarize(file).map { record(from: $0, modifiedAt: file.modifiedAt, agentId: agentId) }
        }
    }

    static func summarize(contentsOf url: URL) -> PiSessionSummary? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return PiSessionFile.parse(data)?.summary()
    }

    func record(from summary: PiSessionSummary, modifiedAt: Date, agentId: String) -> TaskRecord {
        let current = now()
        let updated = summary.lastActivity ?? modifiedAt
        let status = Self.status(tail: summary.tail, updatedAt: updated, modifiedAt: modifiedAt, now: current)
        let projectName = SessionFormatting.projectName(summary.cwd)
        let title = summary.title ?? (projectName.isEmpty ? "Pi 会话" : projectName)
        return TaskRecord(
            id: "pi:\(summary.sessionID)",
            agentId: agentId,
            source: .pi,
            title: title,
            projectPath: summary.cwd,
            projectName: projectName,
            status: status,
            lastMessage: summary.lastAssistantText,
            origin: .desktop,
            // 非 running 的都能 `--session` 续上；running 的桌面会话我们没有它的进程，续了会和它抢同一个文件。
            controllable: status != .running,
            startedAt: ProtocolJSON.timestamp(summary.startedAt ?? updated),
            updatedAt: ProtocolJSON.timestamp(updated))
    }

    /// 状态推断（spec）：24 小时无活动 → idle（与 Codex 一致，让旧的红色状态自然淡出）；
    /// 否则看当前分支最后一条消息，停在"还在等模型"的位置时靠文件的修改时间区分 running / interrupted。
    static func status(tail: PiSessionSummary.Tail, updatedAt: Date, modifiedAt: Date, now: Date) -> TaskStatus {
        if now.timeIntervalSince(updatedAt) > SessionFormatting.idleAfter { return .idle }
        switch tail {
        case .completed: return .completed
        case .failed: return .failed
        case .aborted: return .interrupted
        case .empty: return .idle
        case .open: return now.timeIntervalSince(modifiedAt) <= runningWindow ? .running : .interrupted
        }
    }
}

/// 观察者要的一份会话摘要：状态推断所需的全部，与"现在几点"无关，所以可以按文件缓存。
struct PiSessionSummary: Hashable, Sendable {
    /// 当前分支最后一条消息停在哪儿。
    enum Tail: Hashable, Sendable {
        /// assistant 且 `stopReason` 为 `stop` / `length`。
        case completed
        /// assistant 且 `stopReason` 为 `error`。
        case failed
        /// assistant 且 `stopReason` 为 `aborted`（用户按了 Esc / 我们发了 SIGINT）。
        case aborted
        /// 还在等模型：最后是 user、toolResult，或 assistant 停在 `toolUse` / `pending` / `deferred`。
        case open
        /// 只有 header，一条消息都没有。
        case empty
    }

    var sessionID: String
    var cwd: String
    /// `session_info.name` 或首条 user 文本；都没有时为 nil，由调用方用项目名兜底。
    var title: String?
    var lastAssistantText: String?
    var tail: Tail
    var startedAt: Date?
    var lastActivity: Date?
}

// MARK: - 文件模型

/// 解析后的一份会话文件：header + 全部 entry（文件顺序）。
struct PiSessionFile {
    struct Header {
        var id: String
        var cwd: String
        var timestamp: Date?
    }

    struct Entry {
        enum Kind {
            case message(PiMessage)
            /// 会话标题（`/name` 命令写的）。
            case sessionInfo(name: String?)
            /// `model_change`、`compaction`、`branch_summary`、`label` 等：只占树上的一个节点。
            case other
        }

        var id: String?
        var parentId: String?
        var timestamp: Date?
        var kind: Kind
    }

    var header: Header
    var entries: [Entry]

    /// 首行不是 `type:"session"` 的 header 返回 nil；其余坏行跳过。
    static func parse(_ data: Data) -> PiSessionFile? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).makeIterator()
        guard let first = lines.next(), let header = parseHeader(first) else { return nil }
        var entries: [Entry] = []
        while let line = lines.next() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            entries.append(parseEntry(object))
        }
        return PiSessionFile(header: header, entries: entries)
    }

    /// 只读首行拿 header（续聊要 cwd，不必把几 MB 的会话整份读进来）。
    static func header(atPath path: String) -> Header? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        // header 就一行几百字节；读到换行或 64 KB 为止。
        while buffer.count < 1 << 16 {
            guard let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return parseHeader(buffer[buffer.startIndex..<newline])
            }
        }
        return parseHeader(buffer)
    }

    private static func parseHeader(_ line: Data) -> Header? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              object["type"] as? String == "session",
              let id = object["id"] as? String, !id.isEmpty,
              let cwd = object["cwd"] as? String, !cwd.isEmpty else { return nil }
        return Header(id: id, cwd: cwd, timestamp: PiTimestamp.date(object["timestamp"]))
    }

    private static func parseEntry(_ object: [String: Any]) -> Entry {
        let kind: Entry.Kind
        switch object["type"] as? String {
        case "message":
            kind = (object["message"] as? [String: Any]).flatMap(PiMessage.init(object:)).map { .message($0) } ?? .other
        case "session_info":
            kind = .sessionInfo(name: object["name"] as? String)
        default:
            kind = .other
        }
        return Entry(id: object["id"] as? String, parentId: object["parentId"] as? String,
                     timestamp: PiTimestamp.date(object["timestamp"]), kind: kind)
    }

    /// 当前分支，从根到叶。叶 = 文件里最后一条带 id 的 entry，沿 `parentId` 往回走；
    /// 断链（父节点不在文件里）就停在那儿，成环（坏文件）靠 visited 挡住。
    /// 一条带 id 的都没有（更早的线性格式）时按文件顺序整份当成一条分支。
    var branch: [Entry] {
        guard let leaf = entries.last(where: { $0.id != nil }) else { return entries }
        var byID: [String: Entry] = [:]
        for entry in entries { if let id = entry.id { byID[id] = entry } }
        var path: [Entry] = [leaf]
        var visited: Set<String> = [leaf.id!]
        var cursor = leaf.parentId
        while let id = cursor, !visited.contains(id), let parent = byID[id] {
            visited.insert(id)
            path.append(parent)
            cursor = parent.parentId
        }
        return path.reversed()
    }

    func summary() -> PiSessionSummary {
        let branch = self.branch
        let messages = branch.compactMap { entry -> PiMessage? in
            if case .message(let message) = entry.kind { return message }
            return nil
        }

        // 标题：会话名（整份文件里最后一次命名）> 分支上首条 user 文本 > nil（调用方用项目名）。
        let named = entries.reversed().lazy.compactMap { entry -> String? in
            guard case .sessionInfo(let name) = entry.kind, let name else { return nil }
            let line = PiText.singleLine(name)
            return line.isEmpty ? nil : line
        }.first
        let firstUser = messages.lazy
            .filter { $0.role == .user }
            .map { PiText.singleLine($0.text) }
            .first { !$0.isEmpty }
        let title = (named ?? firstUser).map { SessionFormatting.truncate($0, SessionFormatting.titleLimit) }

        let lastAssistant = messages.reversed().lazy
            .filter { $0.role == .assistant }
            .map(\.text)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // 状态只看"对话"那几种角色；bashExecution 是用户在 pi 里敲的 `!命令`，不代表 agent 在跑。
        let tail: PiSessionSummary.Tail
        switch messages.last(where: { $0.role != .bashExecution && $0.role != .other }) {
        case nil:
            tail = .empty
        case let message? where message.role == .assistant:
            switch message.stopReason {
            case "stop", "length": tail = .completed
            case "error": tail = .failed
            case "aborted": tail = .aborted
            default: tail = .open
            }
        default:
            tail = .open
        }

        let lastActivity = entries.reversed().lazy.compactMap { $0.timestamp ?? $0.messageTimestamp }.first
        return PiSessionSummary(
            sessionID: header.id,
            cwd: header.cwd,
            title: title,
            lastAssistantText: lastAssistant.map { SessionFormatting.truncate($0, SessionFormatting.lastMessageLimit) },
            tail: tail,
            startedAt: header.timestamp ?? entries.lazy.compactMap(\.timestamp).first,
            lastActivity: lastActivity)
    }
}

extension PiSessionFile.Entry {
    var messageTimestamp: Date? {
        if case .message(let message) = kind { return message.timestamp }
        return nil
    }
}

/// `AgentMessage`：只留对话记录与状态推断用得上的部分。
struct PiMessage {
    enum Role: Equatable {
        case user, assistant, toolResult, bashExecution, other
    }

    var role: Role
    /// 文本块拼起来（thinking 不算）。
    var text: String
    /// assistant 的工具调用，已压成一行摘要（`bash: ls` / `edit src/a.ts`）。
    var toolCalls: [String]
    var stopReason: String?
    /// 消息自带的时间（毫秒），比 entry 的 ISO 时间更贴近生成时刻；两者都可能缺。
    var timestamp: Date?
    /// `bashExecution` 的命令。
    var command: String?
    /// user 消息里的图片块，base64 原样留着：观察者每次对账都整份解析会话文件，却只要标题与状态，
    /// 在这里解码等于每轮白解一遍所有图。只有读对话记录时才解（`PiMessageReader`）。
    var imageBlocks: [(data: String, mimeType: String)]

    init?(object: [String: Any]) {
        guard let role = object["role"] as? String else { return nil }
        switch role {
        case "user": self.role = .user
        case "assistant": self.role = .assistant
        case "toolResult": self.role = .toolResult
        case "bashExecution": self.role = .bashExecution
        default: self.role = .other
        }
        stopReason = object["stopReason"] as? String
        timestamp = PiTimestamp.date(object["timestamp"])
        command = object["command"] as? String

        var texts: [String] = []
        var tools: [String] = []
        var images: [(data: String, mimeType: String)] = []
        if let content = object["content"] as? String {
            texts.append(content)
        } else if let blocks = object["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { texts.append(text) }
                case "toolCall":
                    if let name = block["name"] as? String, !name.isEmpty {
                        tools.append(Self.toolSummary(name: name, arguments: block["arguments"]))
                    }
                case "image":
                    if let data = block["data"] as? String, let mimeType = block["mimeType"] as? String {
                        images.append((data, mimeType))
                    }
                // thinking 等一律不进正文。
                default:
                    break
                }
            }
        }
        text = texts.joined(separator: "\n")
        // toolResult 的正文往往是整个文件或一屏日志，工具调用也只有 assistant 会发。
        toolCalls = self.role == .assistant ? tools : []
        // 只收用户发的图：assistant 与 toolResult 里的图是工具截图，不进对话。
        imageBlocks = self.role == .user ? images : []
    }

    /// 一次工具调用的一行摘要。Pi 的内置工具是 read / bash / edit / write / grep / find / ls，
    /// 参数名按常见的几个认；认不出来就只给工具名——手机上没人要看参数 JSON。
    static func toolSummary(name: String, arguments: Any?) -> String {
        var object = arguments as? [String: Any]
        // 有的 provider 把 arguments 存成 JSON 字符串。
        if object == nil, let raw = arguments as? String, let data = raw.data(using: .utf8) {
            object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let object else { return name }
        if let command = object["command"] as? String, !command.isEmpty {
            return "\(name): \(PiText.singleLine(command))"
        }
        for key in ["path", "file_path", "filePath", "pattern", "query", "url"] {
            if let value = object[key] as? String, !value.isEmpty { return "\(name) \(PiText.singleLine(value))" }
        }
        return name
    }
}

enum PiText {
    /// 标题与工具摘要必须单行：换行与连续空白压成一个空格。
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// entry 的 `timestamp` 是 ISO 字符串，消息里的 `timestamp` 是毫秒数；两种都认。
enum PiTimestamp {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func date(_ value: Any?) -> Date? {
        switch value {
        case let string as String:
            return (try? fractional.parse(string)) ?? (try? plain.parse(string))
        case let number as NSNumber:
            // JSONSerialization 把 true/false 也给成 NSNumber，别把它当成 1970 年。
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value > 0 else { return nil }
            // 大于 1e11 的按毫秒（秒级要到 5138 年才有这么大）。
            return Date(timeIntervalSince1970: value > 1e11 ? value / 1000 : value)
        default:
            return nil
        }
    }
}

// MARK: - 观察者的数据源

/// 给 `SessionObserver` 的 Pi 数据源。按 (路径, 修改时间, 大小) 缓存每份文件的摘要：
/// 观察者每 3 秒一轮，200 份会话里通常只有一两份在变，没必要每轮把几十 MB 的 JSONL 全部重读。
/// 状态里与"现在几点"有关的那部分（running 窗口、idle）不进缓存，每轮现算。
public final class PiSessionSource: SessionSnapshotSource, @unchecked Sendable {
    private struct Cached {
        var modifiedAt: Date
        var size: Int
        var summary: PiSessionSummary?
    }

    private let reader: PiSessionReader
    private let lock = NSLock()
    private var cache: [URL: Cached] = [:]

    public init(paths: PiPaths = PiPaths(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = PiSessionReader(paths: paths, now: now)
    }

    public func readSnapshot(agentId: String) throws -> (tasks: [TaskRecord], projects: [Project]) {
        // 整轮握着锁：观察者本来就是串行轮询，锁只是防 app 里别处同时调用。
        lock.lock()
        defer { lock.unlock() }
        var seen: [URL: Cached] = [:]
        let tasks = try reader.readTasks(agentId: agentId) { file in
            if let hit = cache[file.url], hit.modifiedAt == file.modifiedAt, hit.size == file.size {
                seen[file.url] = hit
                return hit.summary
            }
            let summary = PiSessionReader.summarize(contentsOf: file.url)
            seen[file.url] = Cached(modifiedAt: file.modifiedAt, size: file.size, summary: summary)
            return summary
        }
        // 只留这一轮还在窗口里的文件，缓存不会无限长。
        cache = seen
        return (tasks, SessionFormatting.projects(from: tasks, agentId: agentId))
    }
}
