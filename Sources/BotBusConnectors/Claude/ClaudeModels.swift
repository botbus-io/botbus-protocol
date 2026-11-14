import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// `claude` 自己报的模型列表里的一项（`ClaudeModels.list(binary:)`）。
public struct ClaudeListedModel: Hashable, Sendable {
    public var option: ModelOption
    /// 这一项现在指向的完整模型名（`claude-opus-5-5`）。别名（`opus`）随 Claude Code 升级会指到新模型，
    /// 带版本的那几项（`claude-fable-5`）指向自己。认 transcript 里用过的模型时按它对。
    public var resolved: String?

    public init(option: ModelOption, resolved: String? = nil) {
        self.option = option
        self.resolved = resolved
    }
}

/// 协议 3.2：Claude Code 在手机上（以及团队看板的员工）能选的模型。
///
/// 优先用 `claude` 自己报的列表（`list(binary:)`：起一次 `claude -p`，发控制协议的 `initialize`，应答里的 `models`
/// 就是它 `/model` 选择器里的那份——别名、带版本的老模型、各自支持的思考强度），所以同一系列的几个版本
/// （Fable 5、Fable 5.2）都能选。问不到时（老版本不报、没登录、超时）退回下面这份写死的别名：
/// `--model` 认的几个别名（总是指向该系列最新的模型），强度从本机 `claude --help` 的 `--effort` 列表读取，
/// Haiku 不报强度。
///
/// 退回的那份里别名本身不带版本，显示名里的版本号（「Opus 5.5」）来自 transcript 里见过的完整模型名
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

    // MARK: - claude 自己报的列表

    static let listRequestID = "botbus-models"
    /// 等 `initialize` 应答的上限。实测 0.3 秒左右；没登录、卡在网络上时不该让调用方（新建任务前的校验）一直等。
    static let listTimeout: TimeInterval = 15

    /// 问 `claude` 它现在有哪些模型：起一次不带 prompt 的 `claude -p`（同手机那一轮的 stream-json），
    /// 写一行控制协议的 `initialize`，应答里的 `models` 就是 `/model` 选择器的那份。不发消息，不花 token，
    /// 也不留会话记录（没有 user 消息就不写 transcript）。
    ///
    /// 探测本身会触发用户配的 SessionStart / SessionEnd hook，所以带一份只写了 `disableAllHooks` 的临时设置文件
    /// （用文件而不是命令行上的 JSON：Windows 上经 `.cmd` 包装时引号会被吃掉）。应答到了就关 stdin、
    /// 还活着就终止，然后**等它真的退出**才返回（实测 claude 收尾要 1 秒左右；`exitGrace` 秒还不退就强制结束）。
    /// 不能拿到答案就返回：`Process` 在子进程还活着时被释放，同一个进程里之后别处的 `waitUntilExit()`
    /// 会永远等不到退出（连接器的完整测试里，排在后面的 Dsh 真 node 解码就这样卡死过）。
    /// 问不到（老版本不报 `models`、起不来、超时）返回 nil，调用方退回写死的别名。
    static func list(binary: String, timeout: TimeInterval = listTimeout, exitGrace: TimeInterval = 5) async -> [ClaudeListedModel]? {
        let settings = FileManager.default.temporaryDirectory
            .appendingPathComponent("botbus-claude-models-\(UUID().uuidString).json")
        guard (try? Data(#"{"disableAllHooks":true}"#.utf8).write(to: settings, options: .atomic)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: settings) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--settings", settings.path]
        process.environment = ClaudeConnector.environment(adding: [:])
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        // stderr 没人读，同 `ClaudeConnector.run`。
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        let channel = ClaudeControlChannel(handle: input.fileHandleForWriting)
        let exited = OneShotContinuation<Void>()
        process.terminationHandler = { _ in exited.resume(returning: ()) }
        do {
            try PlatformProcess.run(process)
        } catch {
            channel.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            return nil
        }

        let reading = output.fileHandleForReading
        let lines = LineCollector()
        let answer = OneShotContinuation<[ClaudeListedModel]?>()
        reading.portableReadabilityHandler = { handle in
            let chunk = handle.availableData
            // EOF：没答就退出了（没登录、不认这些参数）。
            guard !chunk.isEmpty else {
                answer.resume(returning: nil)
                return
            }
            for line in lines.append(chunk) {
                if let models = initializeModels(inLine: line) { answer.resume(returning: models) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { answer.resume(returning: nil) }
        channel.send(listRequest)
        let models = (try? await answer.value()) ?? nil
        reading.finishPortableReading()
        channel.close()
        // 等它真的退出再返回：不等的话 `Process` 在子进程还活着时就释放了，每问一次留下一个没人收的子进程。
        // SIGTERM 可以被忽略，`exitGrace` 秒后强制结束，保证这里一定返回。
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + exitGrace) {
            guard process.isRunning else { return }
            #if os(Windows)
            PlatformProcess.interrupt(process.processIdentifier)
            #else
            kill(process.processIdentifier, SIGKILL)
            #endif
        }
        try? await exited.value()
        return models.flatMap { $0.isEmpty ? nil : $0 }
    }

    static var listRequest: Data {
        Data(#"{"type":"control_request","request_id":"\#(listRequestID)","request":{"subtype":"initialize"}}"#.utf8) + [0x0A]
    }

    /// stdout 的一行是不是我们那条 `initialize` 的应答；是就解出模型列表（应答里没有 `models` 时是空数组——
    /// 老版本，不用再等），别的行（hook 事件、别的控制消息）是 nil。
    static func initializeModels(inLine line: Data) -> [ClaudeListedModel]? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              response["request_id"] as? String == listRequestID else { return nil }
        let models = (response["response"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
        return listed(models)
    }

    /// `initialize` 应答的 `models` 换成手机认的选项，顺序照旧。
    ///
    /// - `default` 不收：它就是「不带 `--model`」，手机与团队看板各有自己的「默认」。
    /// - id 过不了 `ModelOption.isValidId` 的不收（`opus[1m]` 这类带方括号的上下文档位，协议的 id 写不下）。
    /// - 强度只认 `supportsEffort` 为真且列了 `supportedEffortLevels` 的；没列的当作不能调（Haiku 4.5）。
    static func listed(_ models: [[String: Any]]) -> [ClaudeListedModel] {
        var seen: Set<String> = []
        var result: [ClaudeListedModel] = []
        for model in models {
            guard let id = model["value"] as? String, id != "default", ModelOption.isValidId(id),
                  seen.insert(id).inserted else { continue }
            let name = (model["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var efforts: [String] = []
            if model["supportsEffort"] as? Bool == true {
                for effort in model["supportedEffortLevels"] as? [String] ?? []
                where ModelOption.isValidEffort(effort) && !efforts.contains(effort) {
                    efforts.append(effort)
                }
            }
            let option = ModelOption(id: id,
                                     displayName: String((name.isEmpty ? id : name).prefix(ModelOption.displayNameLimit)),
                                     efforts: efforts.isEmpty ? nil : Array(efforts.prefix(ModelOption.maxEfforts)))
            result.append(ClaudeListedModel(option: option, resolved: model["resolvedModel"] as? String))
            if result.count == ModelOption.maxModels { break }
        }
        return result
    }

    /// 按换行把 stdout 切成行；一行可能分几块到（`initialize` 的应答有几十 KB）。
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()

        func append(_ chunk: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            pending.append(chunk)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(pending.subdata(in: pending.startIndex..<newline))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }

    static func option(_ id: String?, in options: [ModelOption] = options) -> ModelOption? {
        id.flatMap { id in options.first { $0.id == id } }
    }

    /// transcript 里记的是完整的模型名（`claude-opus-5-5`、`claude-sonnet-5[1m]`），换成手机认得的别名；
    /// 认不出的（第三方 provider、`<synthetic>`）是 nil，手机就显示「默认」而不是一个对不上的名字。
    static func optionId(forTranscriptModel model: String) -> String? {
        parse(transcriptModel: model)?.id
    }

    /// 有 `claude` 自己报的列表时，transcript 里的完整模型名对到列表里指向它的那一项（几项都指着时取排在前面的）：
    /// `claude-opus-5-5` → 别名 `opus`，没有别名指着的就是带版本的那一项（`claude-fable-5` → `claude-fable-5`）。
    /// 列表里没有的（已经下架的老模型、第三方 provider）是 nil——不再像写死的别名那样把 `claude-opus-4-1` 说成「Opus」。
    static func optionId(forTranscriptModel model: String, in listed: [ClaudeListedModel]) -> String? {
        let name = normalized(transcriptModel: model)
        return (listed.first { $0.resolved == name } ?? listed.first { $0.option.id == name })?.option.id
    }

    /// 去掉上下文档位 `[1m]` 与 Vertex 的 `@日期`，统一成小写。
    static func normalized(transcriptModel model: String) -> String {
        let lowered = model.lowercased()
        guard let cut = lowered.firstIndex(where: { $0 == "[" || $0 == "@" }) else { return lowered }
        return String(lowered[..<cut])
    }

    /// 完整模型名里的版本号：`claude-opus-5-5` → [5, 5]，`claude-haiku-4-5-20251001` → [4, 5]（日期不算），
    /// `claude-sonnet-5[1m]` → [5]，老式的 `claude-3-5-sonnet-20241022` → [3, 5]。没有版本号的是 nil。
    static func version(forTranscriptModel model: String) -> [Int]? {
        parse(transcriptModel: model)?.version
    }

    private static func parse(transcriptModel model: String) -> (id: String, version: [Int]?)? {
        // `[1m]` 是上下文档位，Vertex 的名字带 `@日期`。
        let lowered = normalized(transcriptModel: model)
        guard lowered.hasPrefix("claude-") else { return nil }
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
