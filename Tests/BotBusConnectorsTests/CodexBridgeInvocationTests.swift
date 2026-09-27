import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class CodexBridgeInvocationTests: XCTestCase {
    func testDesktopInvocationWithLeadingConfigOverridesUsesBridge() {
        let arguments = [
            "-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled",
            "-c", "plugins.codex-app-tools@openai-bundled.mcp_servers.codex_app.enabled=true",
        ]
        XCTAssertTrue(CodexBridgeInvocation.isAppServer(arguments))
    }

    func testOnlyAppServerSubcommandUsesBridge() {
        XCTAssertTrue(CodexBridgeInvocation.isAppServer(["app-server"]))
        XCTAssertTrue(CodexBridgeInvocation.isAppServer(["--config=features.foo=true", "app-server"]))
        XCTAssertFalse(CodexBridgeInvocation.isAppServer(["exec", "app-server"]))
        XCTAssertFalse(CodexBridgeInvocation.isAppServer(["-c", "app-server", "exec"]))
        XCTAssertFalse(CodexBridgeInvocation.isAppServer(["--", "app-server"]))
    }
}
