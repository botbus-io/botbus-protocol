import Foundation
import BotBusConnectorKit
import BotBusProtocol

/// 送不到了的审批 / 提问（见 `ClaudeConnector.answerLate`）：hook 被 Claude Code 掐掉或到了时限、
/// 手机那一轮超时已按拒绝回、进程已经退出。手机上照样点得到，回答改成一条续聊。
struct ClaudeLateRequest: Sendable {
    var sessionID: String
    /// 当时那张卡片。拼续聊只用它：审批看 summary / detail，提问看 questions。
    var request: PendingRequest
    /// 电脑上的会话（hook）：发之前看 transcript，电脑上已经处理过就不发。手机那一轮里为 nil——
    /// 超时已按拒绝回过，transcript 里本来就有这个工具的结果。
    var transcriptPath: String?
    var since: Date

    /// 改发的续聊；拒绝 / 跳过返回 nil（只收卡片）。提问一个都没选时报错，卡片留着。
    func followUp(decision: Command.Approve.Decision, answers: [String: [String]]?) throws -> String? {
        guard decision == .allow else { return nil }
        guard let questions = request.questions, !questions.isEmpty else { return Self.approval(request) }
        guard let text = Self.answers(questions, answers ?? [:]) else {
            throw ConnectorError("没有收到选项，请先选好再提交")
        }
        return text
    }

    /// 操作内容只取第一行、最多这么多字：够 Claude 认出批的是哪一步，对话里也不刷屏。
    static let detailLimit = 200

    /// `已批准：Bash · npm test，请继续。`
    static func approval(_ request: PendingRequest) -> String {
        let lines = (request.detail ?? "").split(whereSeparator: \.isNewline).map { String($0).trimmed }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return "已批准：\(request.summary)，请继续。" }
        var detail = String(first.prefix(detailLimit))
        if lines.count > 1 || first.count > detailLimit { detail += "…" }
        return "已批准：\(request.summary) · \(detail)，请继续。"
    }

    /// 一题只发答案；多题按题目顺序一行一题「问题 答案」。多选用 `, ` 连（同 `claudeAnswers`）。没选任何答案返回 nil。
    static func answers(_ questions: [PendingQuestion], _ answers: [String: [String]]) -> String? {
        let picked = questions.compactMap { question -> (question: String, answer: String)? in
            let values = (answers[question.id] ?? []).map(\.trimmed).filter { !$0.isEmpty }
            return values.isEmpty ? nil : (question.question.trimmed, values.joined(separator: ", "))
        }
        guard !picked.isEmpty else { return nil }
        if questions.count == 1 { return picked[0].answer }
        return picked.map { item in
            // 问题自带问号、冒号的不再加冒号；半角的隔一个空格。
            let separator: String
            if item.question.hasSuffix("？") || item.question.hasSuffix("：") {
                separator = ""
            } else if item.question.hasSuffix("?") || item.question.hasSuffix(":") {
                separator = " "
            } else {
                separator = "："
            }
            return item.question + separator + item.answer
        }.joined(separator: "\n")
    }
}
