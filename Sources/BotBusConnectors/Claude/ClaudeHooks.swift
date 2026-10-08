import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 定位 `~/.claude` 下的东西与 `claude` 可执行文件。
public struct ClaudePaths: Sendable {
    public var claudeHome: URL
    /// Claude 桌面 App 的会话记录目录（`claude-code-sessions`），只读，见 `ClaudeDesktopSessionIndex`。
    public var desktopSessionsDirectories: [URL]

    /// - Parameter desktopSessionsDirectories: nil = 默认 Claude 目录时用桌面 App 的位置；自定的 Claude 目录
    ///   （测试、`CLAUDE_CONFIG_DIR`）对不上桌面 App 的记录，不读。
    public init(claudeHome: URL = ClaudePaths.defaultClaudeHome, desktopSessionsDirectories: [URL]? = nil) {
        self.claudeHome = claudeHome
        self.desktopSessionsDirectories = desktopSessionsDirectories
            ?? (claudeHome == Self.defaultClaudeHome ? Self.defaultDesktopSessionsDirectories : [])
    }

    /// 桌面 App 存会话记录的地方：macOS 在 `~/Library/Application Support/Claude`，Windows 在 `%APPDATA%\Claude`
    /// 与 Microsoft Store 版的虚拟化目录（同 `desktopClaudeCodeRoots`）；Linux 没有桌面 App。
    public static var defaultDesktopSessionsDirectories: [URL] {
        #if os(macOS)
        let roots = [(desktopClaudeCodeRoot as NSString).deletingLastPathComponent]
        #elseif os(Windows)
        let roots = desktopDataRoots(fileManager: .default)
        #else
        let roots: [String] = []
        #endif
        return roots.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("claude-code-sessions", isDirectory: true) }
    }

    /// Linux / Windows 上认 Claude Code 自己的 `CLAUDE_CONFIG_DIR`（后台进程拿得到用户的环境变量；Mac 的 GUI 进程拿不到，照旧）。
    public static var defaultClaudeHome: URL {
        #if !canImport(Darwin)
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], PlatformPath.isAbsolute(custom) {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    public var settingsFile: URL { claudeHome.appendingPathComponent("settings.json") }
    /// 装 hook 之前先把原文件整份复制到这里（spec 6.3）。卸载时不用它——卸载是精确撤回，
    /// 备份是给"我们把用户的文件搞坏了"留的后路。
    public var backupFile: URL { claudeHome.appendingPathComponent("settings.json.botbus.bak") }
    /// `~/.claude/projects`，目录名是把项目绝对路径里的 `/` 换成 `-` 得到的。
    public var projectsDirectory: URL { claudeHome.appendingPathComponent("projects", isDirectory: true) }

    /// 本机装没装 Claude Code。`~/.claude/projects` 存在就算"用过"，可执行文件另判。
    public func hasClaudeHome(fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: claudeHome.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `claude` 可执行文件。装法有好几种（官方安装器、npm 全局、Homebrew），挨个看一遍。
    /// 不走 `which`：Agent 是 GUI 进程，拿不到用户 shell 的 PATH。
    public static let knownBinaries = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]

    /// 手机那一轮、终端接续与「在终端中打开」用的 `claude`：本机找得到的几份里版本最高的那份。
    ///
    /// 命令行装的常常几个月不升级，Claude 桌面 app 自带的那份跟着桌面 app 自动更新，所以谁新用谁，
    /// 手机那一轮多半就和桌面 app 是同一版。两份的登录态是同一份（macOS 的钥匙串、其余平台的 `~/.claude`），
    /// 换着用不用重新登录。版本一样时命令行装的优先。
    public static func detectClaudeBinary(fileManager: FileManager = .default) -> String? {
        newest(installedBinaries(fileManager: fileManager)) { version(ofBinary: $0, fileManager: fileManager) }
    }

    /// 本机找得到的 `claude`，命令行装的在前、Claude 桌面 app 自带的在后（版本一样时就按这个顺序挑）。
    static func installedBinaries(fileManager: FileManager = .default) -> [String] {
        var found: [String] = []
        #if os(Windows)
        // Windows：原生安装器的 `~\.local\bin\claude.exe` 优先，其次 npm 全局的 `claude.cmd`、winget、PATH（见 `AgentBinary`）；
        // 桌面 app 自带的每个根（普通安装、Microsoft Store）各取最高的一份。
        if let binary = AgentBinary.detect("claude", fileManager: fileManager) { found.append(binary) }
        for root in desktopClaudeCodeRoots(fileManager: fileManager) {
            if let binary = newestVersionedBinary(in: root, executable: "claude.exe", fileManager: fileManager) { found.append(binary) }
        }
        #else
        // 原生安装器与 Homebrew 的固定位置优先；再按常见全局目录与 nvm 找（npm 全局装的 `claude` 也是原生程序，
        // 不靠 node）。macOS 再加上 Claude 桌面 app 自带的那份。
        if let known = knownBinaries.map({ ($0 as NSString).expandingTildeInPath })
            .first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            found.append(known)
        } else if let binary = AgentBinary.detect("claude", fileManager: fileManager) {
            found.append(binary)
        }
        #if os(macOS)
        if let desktop = newestVersionedBinary(in: desktopClaudeCodeRoot, executable: desktopClaudeCodeExecutable,
                                               fileManager: fileManager) {
            found.append(desktop)
        }
        #endif
        #endif
        return found
    }

    /// 几份里挑版本最高的；一样高时取排在前面的。读不出版本的排在读得出的后面——
    /// 连 `--version` 都跑不起来的那份，多半也跑不了一轮对话。只有一份时不读版本。
    static func newest(_ candidates: [String], version: (String) -> [Int]?) -> String? {
        guard candidates.count > 1 else { return candidates.first }
        var best: (path: String, version: [Int]?)?
        for candidate in candidates {
            let found = version(candidate)
            guard let current = best else {
                best = (candidate, found)
                continue
            }
            guard let found else { continue }
            if current.version.map({ $0.lexicographicallyPrecedes(found) }) ?? true { best = (candidate, found) }
        }
        return best?.path
    }

    /// `claude` 的版本号（`[2, 1, 286]`）。先从路径认（软链接解析到底）：原生安装器指向 `versions/<版本>`，
    /// 桌面 app 自带的在 `claude-code/<版本>/…`，Homebrew cask 在 `Caskroom/claude-code/<版本>/`。
    /// 认不出（npm 全局、Windows 的 `claude.exe`）再跑一次 `--version`，按路径、大小与修改时间记住，升级后自然重读。
    static func version(ofBinary path: String, fileManager: FileManager = .default) -> [Int]? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if let version = versionInPath(resolved) { return version }
        let attributes = try? fileManager.attributesOfItem(atPath: resolved)
        let stamp = [resolved,
                     (attributes?[.size] as? NSNumber)?.stringValue ?? "",
                     (attributes?[.modificationDate] as? Date).map { String($0.timeIntervalSince1970) } ?? ""]
            .joined(separator: "|")
        if let cached = versionCache.withLock({ $0[stamp] }) { return cached }
        // 跑原路径：Windows 上解析出来的路径形如 `/C:/…`，拿去起进程不可靠。
        let version = runVersion(path)
        versionCache.withLock { $0[stamp] = .some(version) }
        return version
    }

    /// 跑过 `--version` 的结果（读不出也记，免得每次都多起一个进程）。
    private static let versionCache = LockedValue<[String: [Int]?]>([:])

    /// 路径末尾几段里离文件最近的一段 `X.Y.Z`。只看末尾几段：再往上是用户自己的目录，碰巧叫 `1.0.0` 也不算。
    static func versionInPath(_ path: String) -> [Int]? {
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        for component in components.suffix(6).reversed() {
            if let version = parseVersion(component) { return version }
        }
        return nil
    }

    /// `2.1.286`、`2.1.286 (Claude Code)` → `[2, 1, 286]`；不是三段数字的不算。
    static func parseVersion<S: StringProtocol>(_ text: S) -> [Int]? {
        let token = text.split(separator: " ").first ?? ""
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    private static func runVersion(_ binary: String) -> [Int]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--version"]
        // 同 `ClaudeConnector.environment`：`environment = nil` 在 macOS 26 上是空环境。
        process.environment = ProcessInfo.processInfo.environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            return nil
        }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        // 读完就关：Linux 的 Foundation 不会在 EOF 时替你关读端。
        try? output.fileHandleForReading.close()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return parseVersion(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    #if os(macOS)
    /// Claude 桌面 app 把 Claude Code 解到 `~/Library/Application Support/Claude/claude-code/<版本>/<哈希>/claude.app`
    ///（早先没有哈希那一层），每个版本一个目录，随桌面 app 自动更新。单独跑时用的是命令行那份登录（钥匙串里的
    /// `Claude Code-credentials`），与桌面 app 自己的登录分开；没登录过要先用它 `claude auth login`。
    static var desktopClaudeCodeRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true).path
    }

    static let desktopClaudeCodeExecutable = "claude.app/Contents/MacOS/claude"
    #endif

    #if os(Windows)
    /// Claude 桌面 app 把 Claude Code 解到 `%APPDATA%\Claude\claude-code\<版本>\claude.exe`，每个版本一个目录
    ///（像 Mac 那样再隔一层哈希目录也认）。
    /// Microsoft Store（MSIX）版的 `%APPDATA%` 是虚拟化的，真实位置在 `%LOCALAPPDATA%\Packages\Claude_<发布者>\LocalCache\Roaming`。
    /// 只装了桌面 app 的电脑靠它才有 `claude`；它的登录态与桌面 app 分开，没登录过要先用它 `claude auth login`。
    static func desktopClaudeCodeRoots(fileManager: FileManager) -> [String] {
        desktopDataRoots(fileManager: fileManager).map { $0 + "\\claude-code" }
    }

    /// 桌面 app 的数据目录（`%APPDATA%\Claude`，Store 版在虚拟化目录里），普通安装的在前。
    static func desktopDataRoots(fileManager: FileManager) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appData = environment["APPDATA"] ?? home + "\\AppData\\Roaming"
        let localAppData = environment["LOCALAPPDATA"] ?? home + "\\AppData\\Local"
        let packages = localAppData + "\\Packages"
        let storeRoots = ((try? fileManager.contentsOfDirectory(atPath: packages)) ?? [])
            .filter { $0.hasPrefix("Claude_") }
            .sorted()
            .map { packages + "\\" + $0 + "\\LocalCache\\Roaming\\Claude" }
        return [appData + "\\Claude"] + storeRoots
    }
    #endif

    /// `root` 下按版本号命名的子目录（`2.1.284`）里，挑版本最高、带 `executable` 的那个。名字不是点分数字的目录不算。
    ///
    /// 版本目录里可以直接是 `executable`，也可以再隔一层哈希目录（桌面 app 2.1.28x 起是
    /// `<版本>/<哈希>/claude.app/…`）；同一版本有几个哈希目录时取 `executable` 修改时间最新的。
    static func newestVersionedBinary(in root: String, executable: String, fileManager: FileManager = .default) -> String? {
        let versions = ((try? fileManager.contentsOfDirectory(atPath: root)) ?? []).compactMap { name -> (name: String, parts: [Int])? in
            let parts = name.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !parts.contains(nil) else { return nil }
            return (name, parts.compactMap { $0 })
        }
        for version in versions.sorted(by: { $1.parts.lexicographicallyPrecedes($0.parts) }) {
            let directory = (root as NSString).appendingPathComponent(version.name)
            let direct = (directory as NSString).appendingPathComponent(executable)
            if PlatformPath.isExecutableFile(direct, fileManager: fileManager) { return direct }
            let hashed = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
                .map { ((directory as NSString).appendingPathComponent($0) as NSString).appendingPathComponent(executable) }
                .filter { PlatformPath.isExecutableFile($0, fileManager: fileManager) }
            let modified = { (path: String) in
                (try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            }
            if let newest = hashed.max(by: { modified($0) < modified($1) }) { return newest }
        }
        return nil
    }
}

/// Claude Code hook 脚本 POST 过来的一条负载。
///
/// **解析一律容错**：字段名随 Claude Code 版本变过（2.1.273 的 `UserPromptSubmit` 用 `prompt`，
/// 文档上写的是 `user_prompt`；`SessionStart` 是 `source`，文档写 `startup_reason`），
/// 而我们没法要求用户锁版本。所以每个字段都给一串候选键，全都取不到就留空——
/// 少一个字段最多是标题难看，解析失败却会让整条 hook 白跑。
public struct ClaudeHookEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case permissionRequest = "PermissionRequest"
        case notification = "Notification"
        case stop = "Stop"
        /// 这一轮因 API 报错（限流、没登录、额度用完……）结束：发的是它而不是 `Stop`。
        case stopFailure = "StopFailure"
        /// 会话进程退出（关窗口、退出 app、`/clear`、`/exit`）。一轮跑到一半被关掉时它是唯一的收尾信号。
        case sessionEnd = "SessionEnd"
    }

    public var kind: Kind
    public var sessionID: String
    public var cwd: String
    public var transcriptPath: String?
    /// `UserPromptSubmit` 的提问内容。
    public var prompt: String?
    /// `PermissionRequest` 的工具名与入参摘要。
    public var toolName: String?
    public var toolInput: String?
    public var toolUseID: String?
    /// `Notification` 的类型与正文。
    public var notificationType: String?
    public var message: String?
    /// `Stop` 自带的最后一条 assistant 文本（2.1.273 起有；没有时回落去读 transcript）。
    public var lastAssistantMessage: String?
    /// `StopFailure` 的错误类别与详情。
    public var error: String?
    public var errorDetails: String?
    /// `PermissionRequest` 是 `AskUserQuestion` 时解出来的提问（协议 2.14 的选项提问）。
    public var askedQuestions: ClaudeAskedQuestions?

    /// 解析 hook 负载。不是本连接器认识的事件（PreToolUse 等）返回 nil，由调用方安静忽略。
    public init?(json data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.init(object: object)
    }

    public init?(object: [String: Any]) {
        guard let raw = ClaudeHookEvent.string(object, "hook_event_name", "hookEventName"),
              let kind = Kind(rawValue: raw) else { return nil }
        self.kind = kind
        sessionID = ClaudeHookEvent.string(object, "session_id", "sessionId") ?? ""
        cwd = ClaudeHookEvent.string(object, "cwd", "workspace_dir") ?? ""
        transcriptPath = ClaudeHookEvent.string(object, "transcript_path", "transcriptPath")
        prompt = ClaudeHookEvent.string(object, "prompt", "user_prompt", "userPrompt")
        toolName = ClaudeHookEvent.string(object, "tool_name", "toolName")
        toolUseID = ClaudeHookEvent.string(object, "tool_use_id", "toolUseId")
        notificationType = ClaudeHookEvent.string(object, "notification_type", "notificationType")
        message = ClaudeHookEvent.string(object, "message")
        lastAssistantMessage = ClaudeHookEvent.string(object, "last_assistant_message", "lastAssistantMessage")
        error = ClaudeHookEvent.string(object, "error")
        errorDetails = ClaudeHookEvent.string(object, "error_details", "errorDetails")
        toolInput = ClaudeHookEvent.summarize(object["tool_input"] ?? object["toolInput"])
        askedQuestions = kind == .permissionRequest
            ? ClaudeAskedQuestions(toolName: toolName, input: object["tool_input"] ?? object["toolInput"])
            : nil
    }

    /// 第一个取到非空字符串的键胜出。
    private static func string(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// `tool_input` 是任意结构，只用来给人看。命令类工具把命令行摘出来，其余压成一行 JSON。
    static func summarize(_ input: Any?) -> String? {
        guard let dictionary = input as? [String: Any] else {
            return (input as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        // Bash 的 command、Edit/Write 的 file_path 是最有信息量的；有就直接用。
        for key in ["command", "file_path", "path", "pattern", "url"] {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `AskUserQuestion` 的提问：Claude 要用户在几个选项里挑，而不是批准一个工具。
///
/// 实测（Claude Code 2.1.273，SDK 模式）：`PermissionRequest` hook 回 `allow` 并在 `updatedInput` 里
/// 带上原入参加 `answers`（问题原文 → 选中的 label，多选用 ", " 连起来），就等于用户在电脑上选了；
/// 与电脑上的提问框先答者生效。`-p` 只有带 permission host 时才有这个工具：本连接器起的 `claude -p` 带
/// `--permission-prompt-tool stdio`，所以手机那一轮里它经控制协议（`ClaudeControlRequest`）到达，回答形状相同。
public struct ClaudeAskedQuestions: Sendable, Equatable {
    public static let toolName = "AskUserQuestion"
    static let textLimit = 2000

    /// 原样的 `tool_input`。`updatedInput` 整份替换入参，所以回答时要把它原封不动带回去再加 `answers`。
    public var rawInput: Data
    /// 给手机的版本，`id` 是问题的下标。
    public var questions: [PendingQuestion]
    /// 与 `questions` 同序的问题原文——`answers` 的键。
    public var texts: [String]

    init?(toolName: String?, input: Any?) {
        guard toolName == Self.toolName, let input = input as? [String: Any],
              let items = input["questions"] as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return nil }
        var questions: [PendingQuestion] = []
        var texts: [String] = []
        for item in items.prefix(PendingQuestion.maxQuestions) {
            guard let text = item["question"] as? String, !text.trimmed.isEmpty else { continue }
            let options = ((item["options"] as? [[String: Any]]) ?? []).prefix(PendingQuestion.maxOptions)
                .compactMap { option -> PendingOption? in
                    guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                    let description = (option["description"] as? String).flatMap { $0.trimmed.isEmpty ? nil : $0 }
                    return PendingOption(label: label, description: description)
                }
            let header = (item["header"] as? String).flatMap { $0.trimmed.isEmpty ? nil : $0 }
            questions.append(PendingQuestion(id: String(questions.count), question: String(text.prefix(Self.textLimit)),
                                             header: header, multiSelect: item["multiSelect"] as? Bool == true,
                                             options: Array(options)))
            texts.append(text)
        }
        guard !questions.isEmpty else { return nil }
        rawInput = data
        self.questions = questions
        self.texts = texts
    }

    /// 一行摘要：第一个问题的短标签，没有就用问题本身；都是空白时「Claude 在等你回答」（`summaryPhrase`）。
    public var summary: String {
        summaryPhrase?.chineseText ?? String(firstLine.prefix(120))
    }

    /// 协议 3.11：摘要是电脑写的那句话时的短语；摘要是问题原文时为 nil。
    public var summaryPhrase: RequestPhrase? {
        firstLine.isEmpty ? .awaitingAnswer(agent: "Claude") : nil
    }

    private var firstLine: String {
        let first = questions[0]
        return (first.header ?? first.question).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    /// 写好选项的纯文字，给不认 `questions` 的旧手机和手表看（它们只会画 `question`）。
    public var plainText: String {
        let blocks = questions.map { question -> String in
            var lines = [question.question + (question.allowsMultiple ? "（可多选）" : "")]
            for (index, option) in question.options.enumerated() {
                lines.append("\(index + 1). \(option.label)" + (option.description.map { " — \($0)" } ?? ""))
            }
            return lines.joined(separator: "\n")
        }
        return String(blocks.joined(separator: "\n\n").prefix(Self.textLimit))
    }

    /// 手机的回答 → Claude 的 `answers`（问题原文 → 答案）。认不出的问题 id 和空答案丢掉。
    public func claudeAnswers(_ answers: [String: [String]]) -> [String: String] {
        var result: [String: String] = [:]
        for (id, values) in answers {
            guard let index = Int(id), texts.indices.contains(index) else { continue }
            let picked = values.map(\.trimmed).filter { !$0.isEmpty }
            guard !picked.isEmpty else { continue }
            result[texts[index]] = picked.joined(separator: ", ")
        }
        return result
    }

    /// 回答后的整份入参：原入参加 `answers`（`updatedInput` 整份替换入参）。
    public func answeredInput(_ answers: [String: String]) -> Data {
        var input = ((try? JSONSerialization.jsonObject(with: rawInput)) as? [String: Any]) ?? [:]
        input["answers"] = answers
        return (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? rawInput
    }

    /// 同一句话回答所有问题：用户没点选项、直接打了字。
    public func claudeAnswers(text: String) -> [String: String] {
        Dictionary(texts.map { ($0, text) }, uniquingKeysWith: { first, _ in first })
    }
}

/// 回给 hook 脚本的 JSON。脚本把它原样吐到 stdout，Claude Code 照此决策。
///
/// `PermissionRequest` 的 `decision` 是个**带 `behavior` 判别式的对象**，不是字符串——
/// 与 `PreToolUse` 的 `permissionDecision` 是两套东西，写错了会被整条忽略然后回落到弹窗。
/// 形状取自本机 Claude Code 2.1.273 的内建 schema。
public enum ClaudeHookOutput {
    public static func permission(allow: Bool, reason: String) -> Data {
        permission(allow ? .allow(updatedInput: nil) : .deny(message: reason))
    }

    public static func permission(_ decision: ClaudePermissionDecision) -> Data {
        let body: [String: Any]
        switch decision {
        case .allow(nil):
            body = ["behavior": "allow"]
        case .allow(let updated?):
            body = ["behavior": "allow",
                    "updatedInput": ((try? JSONSerialization.jsonObject(with: updated)) as? [String: Any]) ?? [:]]
        case .deny(let message):
            body = ["behavior": "deny", "message": message]
        }
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": ClaudeHookEvent.Kind.permissionRequest.rawValue,
                "decision": body,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    /// 替用户回答 `AskUserQuestion`：`allow`，`updatedInput` = 原入参 + `answers`。
    public static func answer(_ asked: ClaudeAskedQuestions, answers: [String: String]) -> Data {
        permission(.allow(updatedInput: asked.answeredInput(answers)))
    }
}
