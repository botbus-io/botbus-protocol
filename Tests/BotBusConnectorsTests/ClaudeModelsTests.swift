import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 协议 3.2：Claude 的模型别名、`--model` / `--effort` 参数，以及从 transcript 认出用过的模型。
final class ClaudeModelsTests: XCTestCase {
    func testModelAndEffortGoBeforeTheStreamFlags() {
        XCTAssertEqual(ClaudeConnector.arguments(resuming: "s1", injection: nil, model: "opus", effort: "high"),
                       ["-p", "--resume", "s1", "--model", "opus", "--effort", "high",
                        "--input-format", "stream-json", "--permission-prompt-tool", "stdio", "--output-format", "stream-json", "--verbose"])
    }

    func testResolveKeepsChoicesAndDropsEffortForHaiku() throws {
        var session = ClaudeConnector.Session(sessionID: "s1", projectPath: "/p", title: "t", titleSource: .prompt,
                                              status: .completed, origin: .desktop,
                                              startedAt: "2026-09-27T08:00:00Z", updatedAt: "2026-09-27T08:00:00Z")
        session.model = "opus"

        let first = try ClaudeConnector.resolve(ModelSelection(effort: "max"), current: session)
        XCTAssertNil(first.model, "只换强度时不把看到的模型钉死")
        XCTAssertEqual(first.effort, "max")

        session.chosenEffort = "max"
        let haiku = try ClaudeConnector.resolve(ModelSelection(model: "haiku"), current: session)
        XCTAssertEqual(haiku.model, "haiku")
        XCTAssertNil(haiku.effort, "Haiku 不能调强度，之前选的强度不再带")

        XCTAssertThrowsError(try ClaudeConnector.resolve(ModelSelection(model: "gpt-5.5"), current: session))

        // 新建任务（协议 3.2 的 startTask.model）：还没有会话。
        let fresh = try ClaudeConnector.resolve(ModelSelection(model: "sonnet", effort: "high"), current: nil)
        XCTAssertEqual(fresh.model, "sonnet")
        XCTAssertEqual(fresh.effort, "high")
        XCTAssertEqual(ClaudeConnector.arguments(resuming: nil, injection: nil, model: "sonnet").prefix(4),
                       ["-p", "--model", "sonnet", "--input-format"])

        session.chosenModel = "haiku"
        XCTAssertThrowsError(try ClaudeConnector.resolve(ModelSelection(effort: "high"), current: session))
    }

    func testTranscriptModelNamesMapToAliases() throws {
        XCTAssertEqual(ClaudeModels.optionId(forTranscriptModel: "claude-opus-5-5"), "opus")
        XCTAssertEqual(ClaudeModels.optionId(forTranscriptModel: "claude-sonnet-5[1m]"), "sonnet")
        XCTAssertNil(ClaudeModels.optionId(forTranscriptModel: "<synthetic>"))
        XCTAssertNil(ClaudeModels.optionId(forTranscriptModel: "deepseek-v4"))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-models-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-fable-5-1","content":[{"type":"text","text":"一"}]}}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"二"}]}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeModels.lastModel(inTranscriptAt: url.path), "claude-sonnet-5", "跳过 <synthetic>，取最后一条真的")
    }

    func testTranscriptModelNamesCarryVersions() {
        XCTAssertEqual(ClaudeModels.version(forTranscriptModel: "claude-opus-5-5"), [5, 5])
        XCTAssertEqual(ClaudeModels.version(forTranscriptModel: "claude-sonnet-5[1m]"), [5])
        XCTAssertEqual(ClaudeModels.version(forTranscriptModel: "claude-haiku-4-5-20251001"), [4, 5], "日期不算版本")
        XCTAssertEqual(ClaudeModels.version(forTranscriptModel: "claude-3-5-sonnet-20241022"), [3, 5])
        XCTAssertEqual(ClaudeModels.version(forTranscriptModel: "claude-opus-4-1@20250805"), [4, 1])
        XCTAssertEqual(ClaudeModels.optionId(forTranscriptModel: "claude-3-5-sonnet-20241022"), "sonnet")
        XCTAssertNil(ClaudeModels.version(forTranscriptModel: "claude-opus"))
    }

    func testDisplayNamesShowTheNewestVersionSeen() {
        // 初始列表没有版本号。
        XCTAssertEqual(ClaudeModels.options.map(\.displayName), ["Fable", "Opus", "Sonnet", "Haiku"])

        var versions: [String: [Int]] = [:]
        XCTAssertTrue(ClaudeModels.note(transcriptModel: "claude-opus-5-5", in: &versions))
        XCTAssertTrue(ClaudeModels.note(transcriptModel: "claude-sonnet-5", in: &versions))
        XCTAssertFalse(ClaudeModels.note(transcriptModel: "claude-opus-4-6", in: &versions), "老会话不把版本拉低")
        XCTAssertFalse(ClaudeModels.note(transcriptModel: "claude-opus-5-5", in: &versions), "同版本不重复触发")
        XCTAssertTrue(ClaudeModels.note(transcriptModel: "claude-opus-6", in: &versions))
        XCTAssertTrue(ClaudeModels.note(transcriptModel: "claude-sonnet-5-1[1m]", in: &versions))
        XCTAssertFalse(ClaudeModels.note(transcriptModel: "<synthetic>", in: &versions))
        XCTAssertEqual(ClaudeModels.options(versions: versions).map(\.displayName),
                       ["Fable", "Opus 6", "Sonnet 5.1", "Haiku"])
    }

    func testClaudeReportsOnlyEffortsSupportedByInstalledCLI() throws {
        try skipPOSIXScriptOnWindows()
        let binary = FileManager.default.temporaryDirectory.appendingPathComponent("claude-help-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: binary) }
        try "#!/bin/sh\nprintf '%s\\n' '  --effort <level>  Effort level (low, medium, high, max)'\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1", name: "本机", appVersion: "1.0"))
        _ = ClaudeConnector(store: store, binary: { binary.path })
        XCTAssertEqual(store.connectors.models(for: .claude)?.map(\.id), ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(store.connectors.models(for: .claude)?.first?.efforts, ["low", "medium", "high", "max"])
        XCTAssertNil(store.connectors.models(for: .claude)?.last?.efforts)
        XCTAssertThrowsError(try ClaudeConnector.resolve(ModelSelection(effort: "xhigh"), current: nil,
                                                       options: try XCTUnwrap(store.connectors.models(for: .claude))))
    }

    /// 2.1.28x 的 `--help` 按 80 列排，档位折到下一行。
    func testEffortsWrappedOntoTheNextLine() {
        let help = """
          --effort <level>                      Effort level for the current session
                                                (low, medium, high, xhigh, max)
          --environment <environment_id>        Create a new cloud session that runs on
                                                the given self-hosted environment (beta)
        """
        XCTAssertEqual(ClaudeModels.efforts(inHelp: help), ["low", "medium", "high", "xhigh", "max"])
        // 档位没写出来时不往下一个选项里借括号。
        let bare = """
          --effort <level>                      Effort level for the current session
          --environment <environment_id>        Self-hosted environment (beta)
        """
        XCTAssertNil(ClaudeModels.efforts(inHelp: bare))
        XCTAssertEqual(ClaudeModels.efforts(inHelp: "  --effort <level>  Effort level (low, high)"), ["low", "high"])
    }

    /// 挑中的 claude 换了（桌面 app 更新了自带的那份），手机发起下一轮之前重读强度。
    func testEffortsAreReReadWhenTheChosenBinaryChanges() async throws {
        try skipPOSIXScriptOnWindows()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-help-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func script(_ name: String, _ levels: String) throws -> String {
            let binary = directory.appendingPathComponent(name)
            try "#!/bin/sh\nprintf '%s\\n' '  --effort <level>  Effort level' '                    (\(levels))'\n"
                .write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            return binary.path
        }
        let old = try script("old", "low, medium, high, max")
        let new = try script("new", "low, medium, high, xhigh, max")
        let chosen = Locked(old)
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1", name: "本机", appVersion: "1.0"))
        let connector = ClaudeConnector(store: store, binary: { chosen.current })
        XCTAssertEqual(store.connectors.models(for: .claude)?.first?.efforts, ["low", "medium", "high", "max"])

        chosen.withLock { $0 = new }
        // 项目目录不存在，这一轮起不来；强度在那之前就重读了。
        _ = try? await connector.start(projectPath: directory.appendingPathComponent("absent").path,
                                       prompt: "hi", images: [])
        XCTAssertEqual(store.connectors.models(for: .claude)?.first?.efforts, ["low", "medium", "high", "xhigh", "max"])
    }

    func testClaudeWithoutCLIHasNoModelPicker() {
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1", name: "本机", appVersion: "1.0"))
        _ = ClaudeConnector(store: store, binary: { nil })
        XCTAssertNil(store.connectors.models(for: .claude))
    }
}
