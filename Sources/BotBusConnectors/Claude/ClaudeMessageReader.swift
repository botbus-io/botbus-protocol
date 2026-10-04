import Foundation
#if canImport(os)
import os
#endif
import BotBusProtocol
import BotBusConnectorKit

// MARK: - Claude

/// 从 `~/.claude/projects/<目录>/<sessionId>.jsonl` 读。
///
/// **靠文件名找**：transcript 的文件名就是 session id，所以不必记住 hook 负载里的
/// `transcript_path`——Agent 重启之后那份内存状态就没了，但文件还在。
public struct ClaudeMessageReader: MessageReader {
    public var kind: ConnectorKind { .claude }

    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "claude")
    private let paths: @Sendable () -> ClaudePaths

    public init(paths: @escaping @Sendable () -> ClaudePaths = { ClaudePaths() }) {
        self.paths = paths
    }

    public func entries(taskId: String, limit: Int) async throws -> (entries: [TranscriptEntry], hasMore: Bool) {
        let sessionID = try nativeTaskId(taskId, kind: .claude)
        guard let url = Self.transcriptURL(sessionID: sessionID, in: paths().projectsDirectory) else {
            throw ConnectorError("没找到这个会话的记录文件")
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ConnectorError("读不到会话记录文件")
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        // 整份解析再截尾：JSONL 没有索引，从后往前也得先切行；transcript 通常几百 KB，一次读完最简单。
        // 路径候选只给窗口里的回复认：先不认路径解析全部并记下行号，截完把窗口里的回复那几行按原样重解析一次。
        var ordinals: [String: Int] = [:]
        let all = lines.enumerated().flatMap { line in
            let parsed = Self.entries(from: line.element, ordinal: line.offset, extractPaths: false)
            for entry in parsed where entry.message.role == .agent { ordinals[entry.message.id] = line.offset }
            return parsed
        }
        let (window, hasMore) = TranscriptWindow.latest(all, limit: limit)
        let entries = window.map { entry in
            guard let ordinal = ordinals[entry.message.id] else { return entry }
            return Self.entries(from: lines[ordinal], ordinal: ordinal).first { $0.message.id == entry.message.id } ?? entry
        }
        return (entries, hasMore)
    }

    /// 在 `~/.claude/projects` 下逐个目录找 `<sessionId>.jsonl`。目录名是把项目路径里的 `/`
    /// 换成 `-` 得到的，反解不回来，所以只能扫。
    static func transcriptURL(sessionID: String, in projectsDirectory: URL) -> URL? {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(at: projectsDirectory,
                                                                     includingPropertiesForKeys: nil) else { return nil }
        for directory in directories {
            let candidate = directory.appendingPathComponent("\(sessionID).jsonl")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// 与 Agent SDK delete_session 相同：只移除该会话的顶层 transcript。
    /// 不使用 hook 的任意路径，拒绝目录/文件软链接越界与非 UUID 的路径注入。
    static func deleteTranscript(sessionID: String, in projectsDirectory: URL) throws {
        guard UUID(uuidString: sessionID) != nil else { throw ConnectorError("会话 id 不合法") }
        // swift-corelibs-foundation（Linux / Windows）枚举一个普通文件不报错、只回空列表：先认定它是目录。
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: projectsDirectory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw ConnectorError("会话记录目录不可用，不能删除")
        }
        // 删除不能复用只读查找的 try?：没有权限枚举不等于已经删除。
        let directories: [URL]
        do {
            directories = try FileManager.default.contentsOfDirectory(at: projectsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
        for directory in directories {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let candidate = directory.appendingPathComponent("\(sessionID).jsonl")
            do {
                _ = try candidate.resourceValues(forKeys: [.isRegularFileKey])
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            }
            try removeTranscript(candidate, sessionID: sessionID, in: projectsDirectory)
            return
        }
    }

    /// 按真实路径比：解析后必须正好是 `<projects>/<一层目录>/<sessionId>.jsonl`。不比 `resolvingSymlinksInPath()`
    /// 出来的 `URL`：Windows 上两边的写法对不上，正常的记录也会被拒（`realPath` 与 `PlatformPath` 管分隔符与大小写）。
    private static func removeTranscript(_ url: URL, sessionID: String, in projectsDirectory: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let root = TranscriptFileRefs.realPath(projectsDirectory.path),
              let resolved = TranscriptFileRefs.realPath(url.path),
              let relative = PlatformPath.relativePath(of: resolved, under: root),
              case let parts = PlatformPath.components(String(relative)), parts.count == 2,
              PlatformPath.same(String(parts[1]), "\(sessionID).jsonl") else {
            throw ConnectorError("会话记录路径不安全，不能删除")
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Claude Code 自己注入、被记成 user 行的整块。用户没说过这些话，不该出现在对话记录里。
    static let injectedTags = ["system-reminder", "task-notification"]

    /// transcript 的一行 → 0…n 条：正文（文字、过程说明与用户的图）一条，每个 `tool_use` 各一行 `.tool` 摘要；
    /// 思考、`tool_result` 与元数据行直接丢掉。Claude Code 通常一个内容块写一行，混着写时正文在前。
    ///
    /// `isMeta` 是 Claude Code 自己写进去的 user 行（贴图的 `[Image: …]` 占位、skill 的基目录说明），
    /// `isSidechain` 是子代理的往返——两者都不是这个会话里人与 Agent 的对话，跟会话列表那边
    /// （`ClaudeSessionHistory.promptText`）一样挡掉。
    ///
    /// id：正文用 `uuid`（没有就用行号），工具调用用 `<uuid>#<n>`，重复拉取时保持稳定。
    static func entries(from line: Substring, ordinal: Int, extractPaths: Bool = true) -> [TranscriptEntry] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return [] }
        let type = (object["type"] as? String) ?? (object["role"] as? String)
        guard type == "user" || type == "assistant" else { return [] }
        // `isFiller` 已含 `isMeta`，另挡 resume / 中断时补的 `<synthetic>` 回复与 "[Request interrupted by user]"。
        guard object["isSidechain"] as? Bool != true, !ClaudeConnector.isFiller(object) else { return [] }
        let content = (object["message"] as? [String: Any])?["content"] ?? object["content"]
        let parts = Self.content(from: content, includeImages: type == "user")
        // uuid 优先：同一条消息重复拉取时 id 必须稳定，行号在中途插入时会漂。
        let id = (object["uuid"] as? String) ?? "line-\(ordinal)"
        // transcript 的时间带毫秒；协议要秒精度（Relay 与客户端按字典序、按固定格式解析）。
        let timestamp = ProtocolJSON.timestamp(ClaudeSessionHistory.date(object["timestamp"]) ?? Date(timeIntervalSince1970: 0))
        var result: [TranscriptEntry] = []
        if let entry = transcriptEntry(id: id, role: type == "user" ? .user : .agent, text: parts.text,
                                       images: parts.images, createdAt: timestamp, extractPaths: extractPaths) {
            result.append(entry)
        }
        for (index, summary) in parts.tools.enumerated() {
            if let entry = transcriptEntry(id: "\(id)#\(index + 1)", role: .tool, text: summary, createdAt: timestamp) {
                result.append(entry)
            }
        }
        return result
    }

    /// 一次遍历内容块，同时取文字、图片与工具调用摘要。图片只看顶层的 `image {source: {type: base64, …}}`：
    /// `tool_result` 里嵌的图是工具截图，跟着 tool_result 一起跳过——所以只有 tool_result 的 user 行照旧不出消息。
    static func content(from content: Any?, includeImages: Bool) -> (text: String?, images: [ImageSource], tools: [String]) {
        if let text = content as? String { return (stripInjectedBlocks(text), [], []) }
        guard let blocks = content as? [[String: Any]] else { return (nil, [], []) }
        var texts: [String] = []
        var images: [ImageSource] = []
        var tools: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                // 注入块常自成一行，剥完是空的就别留下一个空气泡；夹在真话后面时只去掉那一段。
                if let text = block["text"] as? String {
                    let stripped = stripInjectedBlocks(text).trimmed
                    if !stripped.isEmpty { texts.append(stripped) }
                }
            case "thinking":
                if let text = narrationText(block) { texts.append(text) }
            case "tool_use":
                if let name = block["name"] as? String {
                    tools.append(Self.toolSummary(name: name, input: block["input"] as? [String: Any]))
                }
            case "image" where includeImages:
                // 只认内嵌 base64；`url` 形状的来源不在本机，拿不到字节。
                guard let source = block["source"] as? [String: Any], source["type"] as? String == "base64",
                      let data = source["data"] as? String, let type = source["media_type"] as? String,
                      let image = ImageSource(base64: data, contentType: type) else { continue }
                images.append(image)
            // tool_result 的正文往往是整个文件或一屏日志，摘要都嫌长，直接跳过。
            default:
                continue
            }
        }
        return (texts.joined(separator: "\n"), images, tools)
    }

    /// 工具调用的一行摘要：shell 亮出命令本身；其余报工具名加最能说明"在干什么"的那个参数
    /// （文件只留文件名，参数常常是整段文件内容，不往外带）。
    static func toolSummary(name: String, input: [String: Any]?) -> String {
        func value(_ key: String) -> String? {
            (input?[key] as? String).map(CodexThreadReader.singleLine).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let command = value("command") { return "$ \(command)" }
        if let path = value("file_path") ?? value("notebook_path") ?? value("path") {
            return "调用 \(name)：\((path as NSString).lastPathComponent)"
        }
        if let detail = ["pattern", "query", "url", "description", "prompt"].lazy.compactMap(value).first {
            return "调用 \(name)：\(detail)"
        }
        return "调用 \(name)"
    }

    /// 过程说明块的正文；普通思考、没有文字的块是 nil。
    ///
    /// 桌面 app（2.1.260 起）在工具调用之间给用户看的那几句话不是 `text` 块，而是服务端写的
    /// thinking 块，只有签名里标着 `narration`；桌面上当正文显示，手机不显示就像丢了消息。
    /// transcript 里没有别的标记，只能照 Claude Code 自己的做法解签名（见 `signatureBlockKind`）。
    static func narrationText(_ block: [String: Any]) -> String? {
        guard block["type"] as? String == "thinking",
              let text = (block["thinking"] as? String)?.trimmed, !text.isEmpty,
              let signature = block["signature"] as? String,
              signatureBlockKind(signature) == "narration" else { return nil }
        return text
    }

    /// thinking 签名里的块类型：base64 解出 protobuf，取字段 2 → 字段 1 → 字段 8 的字符串
    /// （Claude Code 2.1.281 的 `narration_block_indexes` 同样这样认）。任一层解不开都是 nil——
    /// 老版本签名、截断的、坏的，一律按普通思考处理。
    static func signatureBlockKind(_ signature: String) -> String? {
        let padded = signature + String(repeating: "=", count: (4 - signature.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let envelope = ProtobufFields.bytes(field: 2, in: [UInt8](data)),
              let header = ProtobufFields.bytes(field: 1, in: envelope),
              let kind = ProtobufFields.bytes(field: 8, in: header) else { return nil }
        return String(bytes: kind, encoding: .utf8)
    }

    /// 去掉 `<system-reminder>…</system-reminder>` 这类注入块。
    /// 开标签没有对应的闭标签时删到末尾——注入块总是贴在正文后面。
    static func stripInjectedBlocks(_ text: String) -> String {
        var result = text
        for tag in injectedTags {
            while let open = result.range(of: "<\(tag)>") {
                let close = result.range(of: "</\(tag)>", range: open.upperBound..<result.endIndex)
                result.removeSubrange(open.lowerBound..<(close?.upperBound ?? result.endIndex))
            }
        }
        return result
    }
}

/// 只够读 thinking 签名的 protobuf：按字段号取长度前缀的字节（同号多次出现取最后一次，与 protobuf 语义一致）。
/// 必须整段都能解开，否则 nil——解到一半的结构不可信。
private enum ProtobufFields {
    static func bytes(field number: UInt64, in buffer: [UInt8]) -> [UInt8]? {
        var index = 0
        var found: [UInt8]?
        while index < buffer.count {
            guard let key = varint(buffer, &index) else { return nil }
            switch key & 7 {
            case 0:
                guard varint(buffer, &index) != nil else { return nil }
            case 1:
                index += 8
            case 5:
                index += 4
            case 2:
                guard let length = varint(buffer, &index), length <= UInt64(buffer.count - index) else { return nil }
                let end = index + Int(length)
                if key >> 3 == number { found = Array(buffer[index..<end]) }
                index = end
            default:
                return nil
            }
        }
        return index == buffer.count ? found : nil
    }

    private static func varint(_ buffer: [UInt8], _ index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < buffer.count, shift < 64 {
            let byte = buffer[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}
