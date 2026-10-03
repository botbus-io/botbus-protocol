import XCTest
import BotBusProtocol
@testable import BotBusConnectors

final class ClaudeFailureTests: XCTestCase {
    func testSignInTexts() {
        XCTAssertEqual(ClaudeFailure.diagnosis("Not logged in · Please run /login"), .notSignedIn)
        XCTAssertEqual(ClaudeFailure.diagnosis("Invalid API key · Please run /login"), .notSignedIn)
        XCTAssertEqual(ClaudeFailure.diagnosis("OAuth token has expired. Please obtain a new token."), .signInExpired)
        let revoked = #"Failed to authenticate. API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"OAuth access token has been revoked."}}"#
        XCTAssertEqual(ClaudeFailure.diagnosis(revoked), .signInExpired)
    }

    func testUsageLimitTexts() {
        XCTAssertEqual(ClaudeFailure.diagnosis("Claude AI usage limit reached|1791043200"),
                       .usageLimit(resetsAt: "2026-10-03T16:00:00Z"))
        XCTAssertEqual(ClaudeFailure.diagnosis("You've hit your limit · resets 3pm (Asia/Dubai)"), .usageLimit())
        XCTAssertEqual(ClaudeFailure.diagnosis("5-hour limit reached ∙ resets 3pm"), .usageLimit())
        XCTAssertEqual(ClaudeFailure.diagnosis(#"API Error: 429 {"type":"error","error":{"type":"rate_limit_error"}}"#),
                       .usageLimit())
    }

    /// StopFailure 先看结构化的类别（`error`），没有类别才看错误原文（`error_details`）；认不出的类别不下结论。
    func testStopFailureCategories() {
        XCTAssertEqual(ClaudeFailure.diagnosis(category: "rate_limit", details: "429 Too Many Requests"), .usageLimit())
        XCTAssertEqual(ClaudeFailure.diagnosis(category: "rate_limit", details: "Claude AI usage limit reached|1791043200"),
                       .usageLimit(resetsAt: "2026-10-03T16:00:00Z"))
        XCTAssertEqual(ClaudeFailure.diagnosis(category: "billing_error", details: nil), .usageLimit())
        XCTAssertEqual(ClaudeFailure.diagnosis(category: "authentication_failed", details: nil), .notSignedIn)
        XCTAssertEqual(ClaudeFailure.diagnosis(category: "authentication_failed",
                                               details: "OAuth token has expired. Please obtain a new token."),
                       .signInExpired)
        // 认不出的类别：详情里就算像登录问题也不猜。
        XCTAssertNil(ClaudeFailure.diagnosis(category: "server_error", details: "Not logged in"))
        XCTAssertNil(ClaudeFailure.diagnosis(category: "some_future_category", details: "usage limit reached"))
        XCTAssertEqual(ClaudeFailure.diagnosis(category: nil, details: "Not logged in · Please run /login"), .notSignedIn)
        XCTAssertNil(ClaudeFailure.diagnosis(category: nil, details: nil))
    }

    func testOtherTextsAreNotDiagnosed() {
        XCTAssertNil(ClaudeFailure.diagnosis(nil))
        XCTAssertNil(ClaudeFailure.diagnosis("API Error: 529 Overloaded"))
        XCTAssertNil(ClaudeFailure.diagnosis("Error: Reached max turns (5)"))
    }
}
