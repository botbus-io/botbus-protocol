import XCTest
@testable import BotBusConnectors

/// 手机新建的 Claude 会话带名字（`claude --name`）：Claude 桌面 App 导入时、终端 `/resume` 列表里都显示它。
/// 真起进程的部分（老版本不认 `--name` 时去掉重起）在 `AgentToolsInjectionTests`。
final class ClaudeSessionNameTests: XCTestCase {
    func testSessionNameIsThePromptTitleOnOneLine() {
        XCTAssertEqual(ClaudeConnector.sessionName(for: "  修复手表同步\n顺便看看日志  "), "修复手表同步 顺便看看日志")
        XCTAssertEqual(ClaudeConnector.sessionName(for: String(repeating: "长", count: 100))?.count,
                       ClaudeConnector.titleLimit, "和列表里的标题一样截在 80 字")
        XCTAssertNil(ClaudeConnector.sessionName(for: " \n "), "只发图时没有名字")
    }

    /// 名字之后会进终端标题（`claude --resume` 时），不能夹带 ESC 之类的控制字符。
    func testSessionNameDropsControlCharacters() {
        XCTAssertEqual(ClaudeConnector.sessionName(for: "修复\u{1B}]0;x\u{07}同步"), "修复 ]0;x 同步")
    }

    func testNameIsOneArgumentBeforeThePrompt() {
        XCTAssertEqual(ClaudeConnector.arguments(prompt: "修复手表同步", resuming: nil, injection: nil, name: "修复手表同步"),
                       ["-p", "--name=修复手表同步", "修复手表同步", "--output-format", "stream-json", "--verbose"],
                       "写成 --name=…：名字以 - 开头也不会被当成别的选项")
        XCTAssertEqual(ClaudeConnector.arguments(prompt: "接着改", resuming: "s1", injection: nil),
                       ["-p", "--resume", "s1", "接着改", "--output-format", "stream-json", "--verbose"],
                       "续聊不改名")
    }
}
