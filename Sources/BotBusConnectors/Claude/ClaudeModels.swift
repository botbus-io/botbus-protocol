import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 协议 3.2：Claude Code 在手机上能选的模型。
///
/// Claude Code 没有列模型的接口，这里报它 `--model` 认的几个别名（总是指向该系列最新的模型），
/// 强度从本机 `claude --help` 的 `--effort` 列表读取。Haiku 不报强度：它不支持 effort，
/// 换到 Haiku 时连接器也不再带 `--effort`。
///
/// 别名本身不带版本，显示名里的版本号（「Opus 5.5」）来自 transcript 里见过的完整模型名
/// （`claude-opus-5-5`）。启动时补 7 天历史已经会读 transcript，常用的模型几乎立刻就能显示版本；
/// 没见过的只显示系列名（「Sonnet」），用过一次自动补上。
enum ClaudeModels {
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// 顺序即手机上的顺序；Haiku 不能调强度。
    private static let families: [(id: String, name: String, adjustable: Bool)] = [
        ("fable", "Fable", true),
        ("opus", "Opus", true),
        ("sonnet", "Sonnet", true),
        ("haiku", "Haiku", false),
    ]

    /// 没见过任何 transcript 时的初始列表——只有系列名，没有版本号。
    static let options = options(versions: [:])

    /// 显示名带上版本号；没有版本的只显示系列名。`efforts` 是本机 CLI 认的档位（见 `efforts(forBinary:)`）。
    static func options(versions: [String: [Int]], efforts: [String] = efforts) -> [ModelOption] {
        families.map { family in
            let version = versions[family.id].map { " " + $0.map(String.init).joined(separator: ".") } ?? ""
            return ModelOption(id: family.id, displayName: family.name + version,
                               efforts: family.adjustable ? efforts : nil)
        }
    }

    /// 本机 `claude --help` 里 `--effort` 列出的档位。CLI 没装、`--help` 失败或没有列出档位时是 nil，
    /// 连接器就不报 models，避免手机展示不可用的选择。
    static func efforts(forBinary binary: String?) -> [String]? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--help"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            return nil
        }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        // 读完就关：Linux 的 Foundation 不会在 EOF 时替你关读端。
        try? output.fileHandleForReading.close()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0,
              let help = String(data: data, encoding: .utf8) else { return nil }
        return efforts(inHelp: help)
    }

    /// `--effort <level>` 那一项的说明可能折到下一行（新版按 80 列排，档位单独一行），续行一起读：
    /// 续行是缩进过、又不以 `-` 开头的行。
    static func efforts(inHelp help: String) -> [String]? {
        let lines = help.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.contains("--effort <level>") }) else { return nil }
        var entry = String(lines[start])
        for next in lines[(start + 1)...] {
            let trimmed = next.trimmingCharacters(in: .whitespaces)
            guard next.first?.isWhitespace == true, !trimmed.isEmpty, !trimmed.hasPrefix("-") else { break }
            entry += " " + trimmed
        }
        guard let opening = entry.lastIndex(of: "("), let closing = entry.lastIndex(of: ")"),
              opening < closing else { return nil }
        let values = entry[entry.index(after: opening)..<closing]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !values.isEmpty, values.allSatisfy(ModelOption.isValidEffort),
              Set(values).count == values.count else { return nil }
        return Array(values.prefix(ModelOption.maxEfforts))
    }

    static func option(_ id: String?, in options: [ModelOption] = options) -> ModelOption? {
        id.flatMap { id in options.first { $0.id == id } }
    }

    /// transcript 里记的是完整的模型名（`claude-opus-5-5`、`claude-sonnet-5[1m]`），换成手机认得的别名；
    /// 认不出的（第三方 provider、`<synthetic>`）是 nil，手机就显示「默认」而不是一个对不上的名字。
    static func optionId(forTranscriptModel model: String) -> String? {
        parse(transcriptModel: model)?.id
    }

    /// 完整模型名里的版本号：`claude-opus-5-5` → [5, 5]，`claude-haiku-4-5-20251001` → [4, 5]（日期不算），
    /// `claude-sonnet-5[1m]` → [5]，老式的 `claude-3-5-sonnet-20241022` → [3, 5]。没有版本号的是 nil。
    static func version(forTranscriptModel model: String) -> [Int]? {
        parse(transcriptModel: model)?.version
    }

    private static func parse(transcriptModel model: String) -> (id: String, version: [Int]?)? {
        var lowered = model.lowercased()
        guard lowered.hasPrefix("claude-") else { return nil }
        // `[1m]` 是上下文档位，Vertex 的名字带 `@日期`。
        if let cut = lowered.firstIndex(where: { $0 == "[" || $0 == "@" }) { lowered = String(lowered[..<cut]) }
        let parts = lowered.dropFirst("claude-".count).split(separator: "-")
        guard let id = parts.lazy.compactMap({ part in families.first { $0.id == part }?.id }).first else { return nil }
        // 版本号是一两位的数字段；8 位的是发布日期。
        let version = parts.filter { $0.count <= 2 }.compactMap { Int($0) }
        return (id, version.isEmpty ? nil : version)
    }

    /// 把见过的完整模型名记进 `versions`，只往高处改（翻到用旧模型的老会话不会把版本拉低）。
    /// 版本有变化时返回 true。
    static func note(transcriptModel model: String, in versions: inout [String: [Int]]) -> Bool {
        guard let parsed = parse(transcriptModel: model), let version = parsed.version else { return false }
        if let current = versions[parsed.id], !current.lexicographicallyPrecedes(version) { return false }
        versions[parsed.id] = version
        return true
    }

    /// transcript 末尾最后一条 assistant 消息用的完整模型名（认得出别名的那条）。只读末尾一小段、按原始文本找 `"model":"`，
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
            let name = String(text[range.upperBound..<close])
            if optionId(forTranscriptModel: name) != nil { return name }
        }
        return nil
    }
}
