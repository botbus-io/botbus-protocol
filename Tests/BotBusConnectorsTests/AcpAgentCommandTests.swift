import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class AcpAgentCommandTests: XCTestCase {
    private func run(_ arguments: [String], discovery: AcpDiscoveryResult,
                     enabled: [String: Bool] = [:], launcher: AcpLauncherFactory? = nil) async -> (Int32, String, String) {
        let out = Locked<[String]>([])
        let err = Locked<[String]>([])
        let code = await AcpAgentCommand.run(arguments, context: .init(
            discover: { discovery }, enabledOverrides: { enabled },
            launcher: launcher ?? FakeAgentQueue([]).factory,
            output: { line in out.withLock { $0.append(line) } },
            error: { line in err.withLock { $0.append(line) } }))
        return (code, out.withLock { $0.joined(separator: "\n") }, err.withLock { $0.joined(separator: "\n") })
    }

    private let gemini = AcpAgentSpec(id: "gemini", name: "Gemini CLI", executable: "/opt/homebrew/bin/gemini",
                                      arguments: ["--acp"], environment: [:], origin: .registry, defaultEnabled: true)

    func testListShowsAgentsAndProblems() async {
        let result = AcpDiscoveryResult(agents: [gemini], problems: [AcpManifestProblem(file: "/x/bad.json", reason: "坏了")])
        let (code, out, _) = await run(["list"], discovery: result, enabled: ["gemini": false])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("gemini"))
        XCTAssertTrue(out.contains("Gemini CLI"))
        XCTAssertTrue(out.contains("已停用"))
        XCTAssertTrue(out.contains("bad.json"))
    }

    func testCheckPrintsCapabilities() async {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["loadSession": true, "promptCapabilities": ["image": true]]
        let agent = await FakeAcpAgent.make(behavior)
        let (code, out, err) = await run(["check", "gemini"], discovery: AcpDiscoveryResult(agents: [gemini], problems: []),
                                         launcher: FakeAgentQueue([agent]).factory)
        XCTAssertEqual(code, 0, err)
        XCTAssertTrue(out.contains("loadSession: 是"))
        XCTAssertTrue(out.contains("图片: 是"))
    }

    func testCheckWithPromptRunsATurn() async {
        let agent = await FakeAcpAgent.make(FakeAcpBehavior())
        let (code, out, err) = await run(["check", "gemini", "--prompt", "hi"],
                                         discovery: AcpDiscoveryResult(agents: [gemini], problems: []),
                                         launcher: FakeAgentQueue([agent]).factory)
        XCTAssertEqual(code, 0, err)
        XCTAssertTrue(out.contains("好的"))
        XCTAssertTrue(out.contains("end_turn"))
    }

    func testCheckUnknownAgent() async {
        let (code, _, err) = await run(["check", "nope"], discovery: AcpDiscoveryResult(agents: [], problems: []))
        XCTAssertEqual(code, 1)
        XCTAssertTrue(err.contains("nope"))
    }

    func testUsage() async {
        let (code, _, err) = await run([], discovery: AcpDiscoveryResult(agents: [], problems: []))
        XCTAssertEqual(code, 2)
        XCTAssertTrue(err.contains("botbus agent list"))
    }
}
