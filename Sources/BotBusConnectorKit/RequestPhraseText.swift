import BotBusProtocol

/// 协议 3.11：审批短语 → 电脑写进 `PendingRequest.summary` / `detail` 的简体中文（给 3.10 及更早的手机与不认得这一句的手机）。
///
/// 连接器先建短语，再用这里拼出中文，两份说的就是同一件事。手机用自己的语言重写同一句（ClientCore 的
/// `RequestPhraseText.swift`、Android 的 `RequestPhraseText.kt`），它们 zh-Hans 的词条 key 就是这里的原文，改一处要三处一起改。
extension RequestPhrase {
    public var chineseText: String {
        switch kind {
        case .text: text ?? ""
        case .runCommand: "执行命令：\(text ?? "")"
        case .requestCommand: "请求执行命令"
        case .editFiles: "修改 \(itemCount) 个文件：\(joinedItems)"
        case .requestFileChange: "请求修改文件"
        case .requestPermission: tool.map { "\($0) 请求授权" } ?? "请求权限"
        case .requestExtraPermissions: "请求额外权限"
        case .toolCall: "工具调用"
        case .awaitingAnswer: "\(text ?? "") 在等你回答"
        case .workingDirectory: "工作目录：\(text ?? "")"
        case .networkAccess: "网络访问"
        case .networkPolicy: "网络策略调整"
        case .readPaths: "读取：\(joinedItems)"
        case .writePaths: "写入：\(joinedItems)"
        case .options: "可选项：\(joinedItems)"
        case .moreQuestions: "还有 \(count ?? 0) 个问题"
        case .unknown: text ?? ""
        }
    }

    /// 一组原文用顿号连起来；截断过时末尾加「…」。
    private var joinedItems: String { (items ?? []).joined(separator: "、") + (isTruncated ? "…" : "") }

    /// `requestPermission` 的工具名；空串当作没有。
    private var tool: String? { text.flatMap { $0.isEmpty ? nil : $0 } }
}

extension Array where Element == RequestPhrase {
    /// 详情逐行的中文，`\n` 连接。
    public var chineseText: String { map(\.chineseText).joined(separator: "\n") }
}
