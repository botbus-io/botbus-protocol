import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 协议 3.2：Claude Code 在手机上能选的模型。
///
/// Claude Code 没有列模型的接口，这里报它 `--model` 认的几个别名（总是指向该系列最新的模型），
/// 强度是 `--effort` 认的几档（`claude --help`，2.1.283）。Haiku 不报强度：它不支持 effort，
/// 换到 Haiku 时连接器也不再带 `--effort`。
enum ClaudeModels {
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static let options: [ModelOption] = [
        ModelOption(id: "fable", displayName: "Fable", efforts: efforts),
        ModelOption(id: "opus", displayName: "Opus", efforts: efforts),
        ModelOption(id: "sonnet", displayName: "Sonnet", efforts: efforts),
        ModelOption(id: "haiku", displayName: "Haiku"),
    ]

    static func option(_ id: String?) -> ModelOption? {
        id.flatMap { id in options.first { $0.id == id } }
    }

    /// transcript 里记的是完整的模型名（`claude-opus-5-5`、`claude-sonnet-5[1m]`），换成手机认得的别名；
    /// 认不出的（第三方 provider、`<synthetic>`）是 nil，手机就显示「默认」而不是一个对不上的名字。
    static func optionId(forTranscriptModel model: String) -> String? {
        let lowered = model.lowercased()
        guard lowered.hasPrefix("claude-") else { return nil }
        return options.first { lowered.contains($0.id) }?.id
    }

    /// transcript 末尾最后一条 assistant 消息用的模型别名。只读末尾一小段、按原始文本找 `"model":"`，
    /// 不解析整份 JSONL——Stop 时调一次，transcript 可能有几十 MB。
    static func lastModel(inTranscriptAt path: String, tailBytes: Int = 64 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var searchEnd = text.endIndex
        while let range = text.range(of: "\"model\":\"", options: .backwards, range: text.startIndex..<searchEnd) {
            searchEnd = range.lowerBound
            guard let close = text[range.upperBound...].firstIndex(of: "\"") else { continue }
            if let id = optionId(forTranscriptModel: String(text[range.upperBound..<close])) { return id }
        }
        return nil
    }
}
