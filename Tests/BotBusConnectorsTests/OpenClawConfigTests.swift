import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

/// `openclaw.json` 的宽松解析。全部喂文本或临时目录，不读用户的 `~/.openclaw`。
final class OpenClawConfigTests: XCTestCase {
    private let state = URL(fileURLWithPath: "/tmp/openclaw-test-state", isDirectory: true)

    func testDefaultsWhenEmptyOrBroken() {
        for text in ["", "not json at all", "{ gateway: ", "[1, 2]"] {
            let config = OpenClawConfig.parse(text, stateDirectory: state)
            XCTAssertEqual(config.port, 18789, text)
            XCTAssertNil(config.token, text)
            XCTAssertNil(config.password, text)
            XCTAssertEqual(config.workspaceDirectory, "/tmp/openclaw-test-state/workspace", text)
        }
        XCTAssertEqual(OpenClawConfig.parse("").gatewayURL.absoluteString, "ws://127.0.0.1:18789")
    }

    func testJSON5CommentsTrailingCommasAndBareKeys() {
        let text = """
        // OpenClaw 配置
        {
          /* 网关 */
          gateway: {
            port: 19001, // 改过端口
            auth: {
              mode: 'token',
              token: "abc//not-a-comment/*either*/",
            },
          },
          agents: { defaults: { workspace: '~/claw-work', }, },
        }
        """
        let config = OpenClawConfig.parse(text, stateDirectory: state)
        XCTAssertEqual(config.port, 19001)
        XCTAssertEqual(config.token, "abc//not-a-comment/*either*/")
        XCTAssertEqual(config.workspaceDirectory, ("~/claw-work" as NSString).expandingTildeInPath)
        XCTAssertEqual(config.gatewayURL.absoluteString, "ws://127.0.0.1:19001")
        XCTAssertEqual(config.displayAddress, "127.0.0.1:19001")
    }

    func testSingleQuotedStringsWithQuotesAndEscapes() {
        let normalized = OpenClawConfig.normalizedJSON5(#"{a: 'it\'s "quoted"', b: [1, 2,], c: true, d: null}"#)
        let object = try? JSONSerialization.jsonObject(with: Data(normalized.utf8)) as? [String: Any]
        XCTAssertEqual(object?["a"] as? String, #"it's "quoted""#)
        XCTAssertEqual(object?["b"] as? [Int], [1, 2])
        XCTAssertEqual(object?["c"] as? Bool, true)
        XCTAssertTrue(object?["d"] is NSNull)
    }

    func testPasswordAndEnvironmentFallbacks() {
        let text = #"{"gateway": {"port": "18800", "auth": {"mode": "password", "password": "pw"}}}"#
        let config = OpenClawConfig.parse(text, stateDirectory: state,
                                          environment: ["OPENCLAW_GATEWAY_TOKEN": "env-token"])
        XCTAssertEqual(config.port, 18800)
        XCTAssertEqual(config.password, "pw")
        XCTAssertEqual(config.token, "env-token")
    }

    func testEnvironmentPortWinsAndBadPortsAreIgnored() {
        let text = #"{"gateway": {"port": 19001}}"#
        XCTAssertEqual(OpenClawConfig.parse(text, environment: ["OPENCLAW_GATEWAY_PORT": "20002"]).port, 20002)
        XCTAssertEqual(OpenClawConfig.parse(text, environment: ["OPENCLAW_GATEWAY_PORT": "nope"]).port, 19001)
        XCTAssertEqual(OpenClawConfig.parse(#"{"gateway": {"port": 0}}"#).port, 18789)
        XCTAssertEqual(OpenClawConfig.parse(#"{"gateway": {"port": 70000}}"#).port, 18789)
        XCTAssertEqual(OpenClawConfig.parse(#"{"gateway": {"port": true}}"#).port, 18789)
    }

    func testSecretRefAndEnvSubstitution() {
        // SecretRef 对象解不了 → 当作没有；`${VAR}` 按环境变量展开。
        let ref = #"{"gateway": {"auth": {"token": {"source": "env", "id": "X"}}}}"#
        XCTAssertNil(OpenClawConfig.parse(ref).token)
        let substituted = #"{"gateway": {"auth": {"token": "${MY_TOKEN}"}}}"#
        XCTAssertEqual(OpenClawConfig.parse(substituted, environment: ["MY_TOKEN": "t-1"]).token, "t-1")
        XCTAssertNil(OpenClawConfig.parse(substituted).token)
        XCTAssertNil(OpenClawConfig.parse(#"{"gateway": {"auth": {"token": "   "}}}"#).token)
    }

    func testDescriptionRedactsSecrets() {
        let config = OpenClawConfig(port: 18789, token: "super-secret", password: "hunter2")
        XCTAssertFalse("\(config)".contains("super-secret"))
        XCTAssertFalse(String(reflecting: config).contains("hunter2"))
        XCTAssertTrue("\(config)".contains("<redacted>"))
    }

    func testLoadReadsConfigFileFromStateDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openclaw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "{ gateway: { port: 18123, auth: { token: 'from-file' } } }"
            .write(to: directory.appendingPathComponent("openclaw.json"), atomically: true, encoding: .utf8)
        let config = OpenClawConfig.load(paths: OpenClawPaths(stateDirectory: directory), environment: [:])
        XCTAssertEqual(config.port, 18123)
        XCTAssertEqual(config.token, "from-file")
        XCTAssertEqual(config.workspaceDirectory, directory.appendingPathComponent("workspace").path)

        let missing = OpenClawConfig.load(paths: OpenClawPaths(stateDirectory: directory.appendingPathComponent("nope")),
                                          environment: [:])
        XCTAssertEqual(missing.port, 18789)
        XCTAssertNil(missing.token)
    }
}
