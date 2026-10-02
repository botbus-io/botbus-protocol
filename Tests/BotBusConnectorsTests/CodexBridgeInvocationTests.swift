import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class CodexBridgeInvocationTests: XCTestCase {
    func testAuxiliaryAppServersCannotReplaceDesktopBridge() {
        let arguments = ["-c", "features.code_mode_host=true", "app-server"]
        XCTAssertTrue(CodexBridgeInvocation.shouldBridge(arguments, parentBundleIdentifier: "com.openai.codex"))
        XCTAssertFalse(CodexBridgeInvocation.shouldBridge(arguments, parentBundleIdentifier: nil))
        XCTAssertFalse(CodexBridgeInvocation.shouldBridge(arguments, parentBundleIdentifier: "com.openai.codex.computer-use"))
        XCTAssertFalse(CodexBridgeInvocation.shouldBridge(arguments, parentBundleIdentifier: "com.apple.Terminal"))
    }

    func testDesktopNonAppServerInvocationStillPassesThrough() {
        XCTAssertFalse(CodexBridgeInvocation.shouldBridge(["exec", "app-server"], parentBundleIdentifier: "com.openai.codex"))
    }

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
