import Foundation
import BotBusConnectorKit

/// 启动时补回最近的 Claude Code 会话：只读 `~/.claude/projects/<目录>/<sessionId>.jsonl`。
///
/// hooks 只能看见"BotBus 在跑、之后又有动静"的会话，所以刚重启或刚配对时手机上几乎是空的。
/// 这里按 transcript 的修改时间取 7 天内最新的一批交给 `ClaudeConnector` 当初始会话；
/// 之后的 hook 照常在同一个 session id 上更新，连接器仍是唯一权威，这里不轮询。
///
/// 读法上的取舍：
/// - 只扫项目目录下一层的 `*.jsonl`；`<sessionId>/subagents/` 里的子代理记录不是会话。
/// - transcript 能有几十 MB（首条消息就可能带 base64 截图），所以只读开头 `headBytes` 与末尾
///   `tailBytes`，只解析其中完整的行。一行里 `entrypoint` / `cwd` 排在 `message` 后面，首行被截断时
///   由末尾那段补上——每条 attachment / assistant 行都带这两个键。
/// - `entrypoint` 为 `sdk-py` / `sdk-ts` 的是脚本经 Agent SDK 调起的会话，一个自动化项目一周就能跑出
///   几千个，会把人自己的会话挤出列表，所以不补；它们运行时 hook 照样会报上来。`sdk-cli`（`claude -p`）
///   保留：BotBus 从手机起的任务就是这一类。
/// - 整段容错：文件读不了、某行不是 JSON、结构变了，都只是少一条或少一个字段。
enum ClaudeSessionHistory {
    struct Entry: Equatable, Sendable {
        var sessionID: String
        var projectPath: String
        /// nil = 什么都没取到，由连接器用项目名占位。
        var title: String?
        var titleSource: ClaudeConnector.TitleSource
        var lastMessage: String?
        /// 最后一条 assistant 消息用的模型（`ClaudeModels` 的别名），认不出时是 nil。
        var model: String? = nil
        var startedAt: Date
        var updatedAt: Date
    }

    static let headBytes = 64 * 1024
    static let tailBytes = 256 * 1024
    static let excludedEntrypoints: Set<String> = ["sdk-py", "sdk-ts"]

    /// 7 天内被写过的会话，最新的在前，最多 `limit` 条。目录不存在就是空列表。
    static func recentSessions(in projectsDirectory: URL, now: Date, limit: Int,
                               window: TimeInterval = SessionFormatting.recentWindow) -> [Entry] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let since = now.addingTimeInterval(-window)
        let directories = (try? fileManager.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil)) ?? []
        var candidates: [(url: URL, modifiedAt: Date, size: Int)] = []
        for directory in directories {
            guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { continue }
            for url in files where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile ?? false,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= since else { continue }
                candidates.append((url, modifiedAt, values.fileSize ?? 0))
            }
        }
        candidates.sort { $0.modifiedAt > $1.modifiedAt }

        var entries: [Entry] = []
        for candidate in candidates {
            guard entries.count < limit else { break }
            if let entry = summarize(fileAt: candidate.url, size: candidate.size, modifiedAt: candidate.modifiedAt) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// 读一个 transcript 的头尾两段。小文件整份读一次。
    static func summarize(fileAt url: URL, size: Int, modifiedAt: Date) -> Entry? {
        let sessionID = url.deletingPathExtension().lastPathComponent
        guard !sessionID.isEmpty, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headBytes), !head.isEmpty else { return nil }
        // 先便宜地挡掉 SDK 会话：不做 JSON 解析，几千个文件也只是各读一次开头。
        if let entrypoint = rawStringValue(forKey: "entrypoint", in: head, last: false),
           excludedEntrypoints.contains(entrypoint) {
            return nil
        }
        var tail: Data?
        if size > headBytes {
            let offset = UInt64(max(headBytes, size - tailBytes))
            if (try? handle.seek(toOffset: offset)) != nil {
                tail = try? handle.readToEnd()
            }
        }
        return summarize(head: head, tail: tail, headIsWholeFile: size <= headBytes,
                         sessionID: sessionID, modifiedAt: modifiedAt)
    }

    /// - Parameters:
    ///   - head: 文件开头；`headIsWholeFile` 为 false 时最后一段不完整，丢掉。
    ///   - tail: 文件末尾（与 head 不重叠）；第一段不完整，丢掉。nil = 文件整份都在 head 里或读不到。
    static func summarize(head: Data, tail: Data?, headIsWholeFile: Bool,
                          sessionID: String, modifiedAt: Date) -> Entry? {
        var entrypoint: String?
        var cwd: String?
        var customTitle: String?
        var aiTitle: String?
        var firstPrompt: String?
        var lastPrompt: String?
        var lastAssistant: String?
        var model: String?
        var startedAt: Date?

        let headLines = lines(head, dropFirst: false, dropLast: !headIsWholeFile)
        let tailLines = tail.map { lines($0, dropFirst: true, dropLast: false) } ?? []
        for line in headLines + tailLines {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if entrypoint == nil { entrypoint = object["entrypoint"] as? String }
            if let value = object["cwd"] as? String, !value.isEmpty { cwd = value }
            if startedAt == nil { startedAt = date(object["timestamp"]) }
            switch object["type"] as? String {
            case "custom-title":
                if let value = titleValue(object, "customTitle") { customTitle = value }
            case "ai-title":
                if let value = titleValue(object, "aiTitle") { aiTitle = value }
            case "last-prompt":
                if let value = (object["lastPrompt"] as? String)?.trimmed, !value.isEmpty { lastPrompt = value }
            case "user":
                if firstPrompt == nil { firstPrompt = promptText(object) }
            case "assistant":
                if let text = ClaudeConnector.assistantText(object) { lastAssistant = text }
                if let name = (object["message"] as? [String: Any])?["model"] as? String,
                   let alias = ClaudeModels.optionId(forTranscriptModel: name) { model = alias }
            default:
                break
            }
        }

        // 首行被截断时这两个键只在截断的那段里——按原始文本再找一次。
        if entrypoint == nil {
            entrypoint = rawStringValue(forKey: "entrypoint", in: head, last: false)
                ?? tail.flatMap { rawStringValue(forKey: "entrypoint", in: $0, last: false) }
        }
        if cwd == nil {
            cwd = tail.flatMap { rawStringValue(forKey: "cwd", in: $0, last: true) }
                ?? rawStringValue(forKey: "cwd", in: head, last: true)
        }
        if let entrypoint, excludedEntrypoints.contains(entrypoint) { return nil }
        guard let cwd, !cwd.isEmpty else { return nil }
        // 连一句 prompt 都没有的是打开就关掉的空会话，不值得占一行。
        let title = customTitle ?? aiTitle ?? firstPrompt ?? lastPrompt
        guard title != nil || lastAssistant != nil else { return nil }
        let titleSource: ClaudeConnector.TitleSource = customTitle != nil ? .named
            : aiTitle != nil ? .generated
            : title != nil ? .prompt : .placeholder

        return Entry(sessionID: sessionID,
                     projectPath: cwd,
                     title: title.map { String($0.prefix(ClaudeConnector.titleLimit)) },
                     titleSource: titleSource,
                     lastMessage: lastAssistant.map { String($0.prefix(ClaudeConnector.lastMessageLimit)) },
                     model: model,
                     startedAt: min(startedAt ?? modifiedAt, modifiedAt),
                     updatedAt: modifiedAt)
    }

    // MARK: - 运行中跟标题

    /// transcript 末尾 `tailBytes` 里 Claude 起的标题：桌面 app 的 `custom-title` 优先，其次 Claude Code 的
    /// `ai-title`。两者都会随对话反复重写到文件末尾，所以不读整份；只解析含这两个类型名的行。
    static func appTitle(inTranscriptAt path: String) -> (title: String, source: ClaudeConnector.TitleSource)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return nil }
        var customTitle: String?
        var aiTitle: String?
        // 末行可能正写到一半，解析失败自然跳过。
        for line in lines(data, dropFirst: offset > 0, dropLast: false) {
            guard line.range(of: customTitleMarker) != nil || line.range(of: aiTitleMarker) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "custom-title":
                if let value = titleValue(object, "customTitle") { customTitle = value }
            case "ai-title":
                if let value = titleValue(object, "aiTitle") { aiTitle = value }
            default:
                break
            }
        }
        let limit = ClaudeConnector.titleLimit
        if let customTitle { return (String(customTitle.prefix(limit)), .named) }
        if let aiTitle { return (String(aiTitle.prefix(limit)), .generated) }
        return nil
    }

    private static let customTitleMarker = Data("\"custom-title\"".utf8)
    private static let aiTitleMarker = Data("\"ai-title\"".utf8)

    // MARK: - 这一轮收尾了没有

    /// transcript 末尾说明上一轮已经结束的那一行。
    enum TurnEnding: Equatable {
        /// 电脑上按了停止或在权限框里拒绝：Claude Code 只写一行 "[Request interrupted by user…]"，不发 Stop hook。
        case interrupted(at: Date)
        /// 正常结束：Stop hook 跑完后写的 `stop_hook_summary`。hook 没送到 Agent 时靠它补上。
        case completed(at: Date)
    }

    /// 看这一轮的收尾只读末尾这么多：收尾标记之后只跟几行元数据。
    static let turnEndingBytes = 64 * 1024

    /// 末尾最后一条对话行是不是收尾标记。只看 user / assistant 行与 `stop_hook_summary`；
    /// `last-prompt`、`cost-state`、`queue-operation`、标题这类元数据行跳过。最后一条是别的对话 = 还在跑，返回 nil；
    /// 读不到、截断成半行、没有时间戳，同样当作还在跑——宁可多挂一会儿，不能把正在跑的任务改掉。
    static func turnEnding(inTranscriptAt path: String) -> TurnEnding? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(turnEndingBytes) ? size - UInt64(turnEndingBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return nil }
        for line in lines(data, dropFirst: offset > 0, dropLast: false).reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "assistant":
                return nil
            case "user":
                guard ClaudeConnector.isInterruptionMarker(object), let at = date(object["timestamp"]) else { return nil }
                return .interrupted(at: at)
            case "system":
                guard object["subtype"] as? String == "stop_hook_summary" else { continue }
                return date(object["timestamp"]).map { .completed(at: $0) }
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - 解析细节

    static func titleValue(_ object: [String: Any], _ key: String) -> String? {
        guard let value = (object[key] as? String)?.trimmed, !value.isEmpty else { return nil }
        return value
    }

    /// 人真正敲的一条 prompt。跳过 meta 行（系统注入的提醒）、子代理行、只有 tool_result 的行，
    /// 以及 `<command-name>` / `<local-command-stdout>` 这类斜杠命令留下的标签行。
    /// 桌面 app 拼在正文前面的 `<system-reminder>` 先剥掉，否则整条都会被当成标签行跳过。
    static func promptText(_ object: [String: Any]) -> String? {
        guard object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true else { return nil }
        let content = (object["message"] as? [String: Any])?["content"]
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = ClaudeMessageReader.stripInjectedBlocks(text).trimmed
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:") else { return nil }
        return trimmed
    }

    /// 按 `\n` 切行；截断的头尾段各丢掉不完整的那一截。
    static func lines(_ data: Data, dropFirst: Bool, dropLast: Bool) -> [Data] {
        var parts = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Data($0) }
        if dropFirst, !parts.isEmpty { parts.removeFirst() }
        if dropLast, !parts.isEmpty { parts.removeLast() }
        return parts.filter { !$0.isEmpty }
    }

    /// 不做 JSON 解析，直接在原始字节里找 `"key":"value"`（Claude Code 写的是紧凑 JSON）。
    /// 值里的转义交给 JSON 解码；找不到或解不开都是 nil。
    static func rawStringValue(forKey key: String, in data: Data, last: Bool) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        let marker = "\"\(key)\":\""
        guard let markerRange = last ? text.range(of: marker, options: .backwards) : text.range(of: marker) else {
            return nil
        }
        var index = markerRange.upperBound
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let literal = "\"" + text[markerRange.upperBound..<index] + "\""
                return try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    /// transcript 的时间戳带毫秒（`2026-09-24T16:10:00.123Z`），两种都认。
    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return (try? fractional.parse(string)) ?? (try? plain.parse(string))
    }
}
