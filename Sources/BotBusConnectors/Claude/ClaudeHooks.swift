import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 定位 `~/.claude` 下的东西与 `claude` 可执行文件。
public struct ClaudePaths: Sendable {
    public var claudeHome: URL

    public init(claudeHome: URL = ClaudePaths.defaultClaudeHome) {
        self.claudeHome = claudeHome
    }

    public static var defaultClaudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
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

    public static func detectClaudeBinary(fileManager: FileManager = .default) -> String? {
        knownBinaries
            .map { ($0 as NSString).expandingTildeInPath }
            .first { fileManager.isExecutableFile(atPath: $0) }
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

    /// 一行摘要：第一个问题的短标签，没有就用问题本身。
    public var summary: String {
        let first = questions[0]
        let line = (first.header ?? first.question).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "Claude 在提问" : String(line.prefix(120))
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
