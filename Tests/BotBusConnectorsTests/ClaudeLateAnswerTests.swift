import XCTest
@testable import BotBusConnectors
import BotBusProtocol

/// 过期之后改发的那条续聊长什么样。它以用户的身份出现在对话里，Claude 也要靠它认出批的是哪一步。
final class ClaudeLateAnswerTests: XCTestCase {
    private func permission(_ detail: String?) -> PendingRequest {
        PendingRequest(id: "t", kind: .permission, summary: "Bash", detail: detail)
    }

    func testApprovalCarriesToolAndCommand() {
        XCTAssertEqual(ClaudeLateRequest.approval(permission("npm test")), "已批准：Bash · npm test，请继续。")
        XCTAssertEqual(ClaudeLateRequest.approval(permission(nil)), "已批准：Bash，请继续。")
        XCTAssertEqual(ClaudeLateRequest.approval(permission("  \n ")), "已批准：Bash，请继续。")
    }

    /// heredoc、长脚本只留第一行，截掉的地方标省略号。
    func testApprovalKeepsOnlyTheFirstLineOfLongCommands() {
        XCTAssertEqual(ClaudeLateRequest.approval(permission("cat <<'EOF' > a.txt\nhello\nEOF")),
                       "已批准：Bash · cat <<'EOF' > a.txt…，请继续。")
        let long = String(repeating: "x", count: ClaudeLateRequest.detailLimit + 5)
        XCTAssertEqual(ClaudeLateRequest.approval(permission(long)),
                       "已批准：Bash · \(String(repeating: "x", count: ClaudeLateRequest.detailLimit))…，请继续。")
    }

    func testAnswersUseQuestionOrderAndPunctuation() {
        let questions = [
            PendingQuestion(id: "0", question: "Which one?", options: []),
            PendingQuestion(id: "1", question: "部署到哪", options: []),
            PendingQuestion(id: "2", question: "要不要通知", options: []),
        ]
        XCTAssertEqual(ClaudeLateRequest.answers(questions, ["1": ["staging"], "0": [" A ", ""]]),
                       "Which one? A\n部署到哪：staging", "没答的题不写")
        XCTAssertNil(ClaudeLateRequest.answers(questions, ["0": ["  "]]), "一个都没选就没东西可发")
    }

    func testDenyAndSkipSendNothingButEmptyAnswersAreAnError() throws {
        let question = PendingRequest(id: "q", kind: .input, summary: "选",
                                      questions: [PendingQuestion(id: "0", question: "选哪个", options: [])])
        let late = ClaudeLateRequest(sessionID: "s", request: question, transcriptPath: nil, since: Date())
        XCTAssertNil(try late.followUp(decision: .deny, answers: ["0": ["A"]]))
        XCTAssertEqual(try late.followUp(decision: .allow, answers: ["0": ["A"]]), "A")
        XCTAssertThrowsError(try late.followUp(decision: .allow, answers: nil))
    }
}
