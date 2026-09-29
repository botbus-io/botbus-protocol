#if !canImport(os)
import Foundation
import XCTest
@testable import BotBusConnectorKit

/// Linux 上 `os.Logger` 替身的脱敏规则（Apple 上 `PlatformLogger` 就是 os.Logger，不测这个类型）。
final class PlatformLogTests: XCTestCase {
    private enum State { case idle, running }
    private enum Outcome { case failed(String) }
    private struct Boom: Error, CustomStringConvertible { var description: String { "secret-path /home/alice" } }

    /// 默认插值（`init(literalCapacity:interpolationCount:)`）读环境变量；测试直接指定开关。
    private func render(revealing: Bool, _ build: (inout LogMessage.StringInterpolation) -> Void) -> String {
        var interpolation = LogMessage.StringInterpolation(literalCapacity: 0, revealsPrivate: revealing)
        build(&interpolation)
        return LogMessage(stringInterpolation: interpolation).text
    }

    func testUnannotatedScalarsAndPayloadFreeEnumsArePublic() {
        let text = render(revealing: false) {
            $0.appendLiteral("n=")
            $0.appendInterpolation(42)
            $0.appendLiteral(" port=")
            $0.appendInterpolation(UInt16(8080))
            $0.appendLiteral(" t=")
            $0.appendInterpolation(1.5)
            $0.appendLiteral(" ok=")
            $0.appendInterpolation(true)
            $0.appendLiteral(" state=")
            $0.appendInterpolation(State.running)
        }
        XCTAssertEqual(text, "n=42 port=8080 t=1.5 ok=true state=running")
    }

    func testUnannotatedStringsErrorsURLsAndPayloadEnumsAreRedacted() {
        let text = render(revealing: false) {
            $0.appendInterpolation("prompt text")
            $0.appendLiteral("|")
            $0.appendInterpolation(Boom() as Error)
            $0.appendLiteral("|")
            $0.appendInterpolation(URL(fileURLWithPath: "/home/alice/project"))
            $0.appendLiteral("|")
            $0.appendInterpolation(Outcome.failed("token"))
            $0.appendLiteral("|")
            $0.appendInterpolation(Optional(7))
        }
        XCTAssertEqual(text, "<private>|<private>|<private>|<private>|<private>")
    }

    func testExplicitPrivacyWins() {
        let text = render(revealing: false) {
            $0.appendInterpolation("reason", privacy: .public)
            $0.appendLiteral(" ")
            $0.appendInterpolation(42, privacy: .private)
            $0.appendLiteral(" ")
            $0.appendInterpolation(State.idle, privacy: .private)
            $0.appendLiteral(" ")
            $0.appendInterpolation(true, privacy: .private)
            $0.appendLiteral(" ")
            $0.appendInterpolation(2.5, privacy: .private)
            $0.appendLiteral(" ")
            $0.appendInterpolation(Boom(), privacy: .public)
        }
        XCTAssertEqual(text, "reason <private> <private> <private> <private> secret-path /home/alice")
    }

    /// `BOTBUS_LOG_PRIVATE=1`：什么都不脱敏。
    func testRevealingPrintsEverything() {
        let text = render(revealing: true) {
            $0.appendInterpolation("prompt")
            $0.appendLiteral(" ")
            $0.appendInterpolation(Boom(), privacy: .private)
        }
        XCTAssertEqual(text, "prompt secret-path /home/alice")
    }

    /// 真实的调用写法（编译期插值）走同一套规则：默认环境下字符串被脱敏、数字留着。
    func testStringInterpolationSyntax() throws {
        try XCTSkipIf(LogMessage.revealsPrivate, "BOTBUS_LOG_PRIVATE=1 下跑测试时不脱敏")
        let path = "/home/alice"
        let count = 3
        let message: LogMessage = "read \(count) from \(path), public \(path, privacy: .public)"
        XCTAssertEqual(message.text, "read 3 from <private>, public /home/alice")
        let literal: LogMessage = "plain literal"
        XCTAssertEqual(literal.text, "plain literal")
    }
}
#endif
