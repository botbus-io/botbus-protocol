import Foundation

/// 协议 3.11：审批摘要与详情里的一句话，手机据此用自己的界面语言重写（见 PROTOCOL「三、审批与提问」）。
///
/// 连接器生成的 `PendingRequest.summary` / `detail` 是简体中文（「执行命令：…」「工作目录：…」）。3.11 起电脑同时报
/// 拼这些话用的**种类与原始参数**：`PendingRequest.summaryPhrase`（摘要那一句）、`detailPhrases`（详情逐行）、
/// `Notify.bodyPhrase`（推送正文就是请求摘要时）。中文原文照写，留给旧手机与不认得的种类。
///
/// `kind` 是开集：手机遇到不认得的种类、或种类要的参数缺了，整段退回电脑写的原文——摘要退回 `summary`，
/// 详情里只要有一句写不出就整段退回 `detail`，不拼半段。参数是 agent 或电脑上的原文（命令、路径、文件名），不翻译。
public struct RequestPhrase: Codable, Hashable, Sendable {
    public var kind: Kind
    /// 一段原文：`text` 的整句，`runCommand` 的命令，`workingDirectory` 的路径，`awaitingAnswer` 的 agent 名，
    /// `requestPermission` 的工具名（可省略）。
    public var text: String?
    /// 一组原文：`editFiles` 的文件名、`readPaths` / `writePaths` 的路径、`options` 的选项名。1–`maxItems` 个，
    /// 连起来不超过 `maxItemsLength`（见 `list`）。
    public var items: [String]?
    /// 带 `items` 的种类：总个数（省略 = `items` 的个数；`items` 截断过时大于它，句末加「…」）；`moreQuestions`：其余问题的个数。
    public var count: Int?

    public init(kind: Kind, text: String? = nil, items: [String]? = nil, count: Int? = nil) {
        self.kind = kind
        self.text = text
        self.items = items
        self.count = count
    }

    /// `items` 最多几个。
    public static let maxItems = 20
    /// `items` 连起来（算上分隔）最多多少字：一句话就是卡片上的一行、也要塞进推送，超了只留前面的。
    public static let maxItemsLength = 200
    /// 命令、路径、工具名、agent 名这类单段原文最多多少字。`text` 种类（agent 的原话）由连接器按详情的上限截断。
    public static let maxTextLength = 1000

    /// agent 的原话，原样显示。
    public static func text(_ text: String) -> RequestPhrase { RequestPhrase(kind: .text, text: text) }
    /// 「执行命令：<命令>」。
    public static func runCommand(_ command: String) -> RequestPhrase {
        RequestPhrase(kind: .runCommand, text: clamp(command, maxTextLength))
    }
    /// 「请求执行命令」：agent 没说是什么命令。
    public static let requestCommand = RequestPhrase(kind: .requestCommand)
    /// 「修改 <n> 个文件：<文件名>」。
    public static func editFiles(_ names: [String]) -> RequestPhrase { list(.editFiles, names) }
    /// 「请求修改文件」：agent 没说改哪些文件。
    public static let requestFileChange = RequestPhrase(kind: .requestFileChange)
    /// 「<工具> 请求授权」，没有工具名时「请求权限」。
    public static func requestPermission(tool: String? = nil) -> RequestPhrase {
        RequestPhrase(kind: .requestPermission, text: tool.map { clamp($0, maxTextLength) })
    }
    /// 「请求额外权限」（Codex 的 permissions 请求）。
    public static let requestExtraPermissions = RequestPhrase(kind: .requestExtraPermissions)
    /// 「工具调用」：ACP agent 没给工具调用起名字。
    public static let toolCall = RequestPhrase(kind: .toolCall)
    /// 「<agent> 在等你回答」：提问没有短标签也没有问题文字。
    public static func awaitingAnswer(agent: String) -> RequestPhrase {
        RequestPhrase(kind: .awaitingAnswer, text: clamp(agent, maxTextLength))
    }
    /// 「工作目录：<路径>」。
    public static func workingDirectory(_ path: String) -> RequestPhrase {
        RequestPhrase(kind: .workingDirectory, text: clamp(path, maxTextLength))
    }
    /// 「网络访问」。
    public static let networkAccess = RequestPhrase(kind: .networkAccess)
    /// 「网络策略调整」。
    public static let networkPolicy = RequestPhrase(kind: .networkPolicy)
    /// 「读取：<路径>」。
    public static func readPaths(_ paths: [String]) -> RequestPhrase { list(.readPaths, paths) }
    /// 「写入：<路径>」。
    public static func writePaths(_ paths: [String]) -> RequestPhrase { list(.writePaths, paths) }
    /// 「可选项：<选项>」。
    public static func options(_ labels: [String]) -> RequestPhrase { list(.options, labels) }
    /// 「还有 <n> 个问题」。
    public static func moreQuestions(_ count: Int) -> RequestPhrase { RequestPhrase(kind: .moreQuestions, count: count) }

    /// 一组原文：按顺序留到 `maxItems` 个、连起来（每个之间算一个分隔字）不超过 `maxItemsLength` 字为止，
    /// 至少留一个（太长就截断）；丢了的时候 `count` 记总数，两端写句子时末尾加「…」——审批范围不能被悄悄藏起来。
    private static func list(_ kind: Kind, _ values: [String]) -> RequestPhrase {
        var kept: [String] = []
        var length = 0
        for value in values.prefix(maxItems) {
            let item = clamp(value, maxItemsLength)
            let added = item.count + (kept.isEmpty ? 0 : 1)
            if !kept.isEmpty, length + added > maxItemsLength { break }
            kept.append(item)
            length += added
        }
        return RequestPhrase(kind: kind, items: kept, count: values.count > kept.count ? values.count : nil)
    }

    private static func clamp(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    public enum Kind: RawRepresentable, Codable, Sendable, Hashable {
        case text
        case runCommand
        case requestCommand
        case editFiles
        case requestFileChange
        case requestPermission
        case requestExtraPermissions
        case toolCall
        case awaitingAnswer
        case workingDirectory
        case networkAccess
        case networkPolicy
        case readPaths
        case writePaths
        case options
        case moreQuestions
        /// 这个版本还不认得的种类。
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "text": self = .text
            case "runCommand": self = .runCommand
            case "requestCommand": self = .requestCommand
            case "editFiles": self = .editFiles
            case "requestFileChange": self = .requestFileChange
            case "requestPermission": self = .requestPermission
            case "requestExtraPermissions": self = .requestExtraPermissions
            case "toolCall": self = .toolCall
            case "awaitingAnswer": self = .awaitingAnswer
            case "workingDirectory": self = .workingDirectory
            case "networkAccess": self = .networkAccess
            case "networkPolicy": self = .networkPolicy
            case "readPaths": self = .readPaths
            case "writePaths": self = .writePaths
            case "options": self = .options
            case "moreQuestions": self = .moreQuestions
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .text: "text"
            case .runCommand: "runCommand"
            case .requestCommand: "requestCommand"
            case .editFiles: "editFiles"
            case .requestFileChange: "requestFileChange"
            case .requestPermission: "requestPermission"
            case .requestExtraPermissions: "requestExtraPermissions"
            case .toolCall: "toolCall"
            case .awaitingAnswer: "awaitingAnswer"
            case .workingDirectory: "workingDirectory"
            case .networkAccess: "networkAccess"
            case .networkPolicy: "networkPolicy"
            case .readPaths: "readPaths"
            case .writePaths: "writePaths"
            case .options: "options"
            case .moreQuestions: "moreQuestions"
            case .unknown(let value): value
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// 写成一句话要的参数都在：`text` 非空、`items` 非空、`count` ≥ 1（按种类）。不认得的种类为 false。
    /// 手机与电脑的渲染都先过这一关，缺参数的一句话就是写不出来，整段退回原文。
    public var isComplete: Bool {
        let hasText = text.map { !$0.isEmpty } ?? false
        let hasItems = items.map { !$0.isEmpty } ?? false
        switch kind {
        case .text, .runCommand, .awaitingAnswer, .workingDirectory: return hasText
        case .editFiles, .readPaths, .writePaths, .options: return hasItems
        case .moreQuestions: return (count ?? 0) >= 1
        case .requestCommand, .requestFileChange, .requestPermission, .requestExtraPermissions, .toolCall,
             .networkAccess, .networkPolicy:
            return true
        case .unknown: return false
        }
    }

    /// 带 `items` 的种类的总个数（`editFiles` 写进句子的文件数）：`count` 与 `items` 个数里大的那个。
    public var itemCount: Int { max(count ?? 0, items?.count ?? 0) }

    /// `items` 是不是截断过（句末要加「…」）。
    public var isTruncated: Bool { itemCount > (items?.count ?? 0) }
}
