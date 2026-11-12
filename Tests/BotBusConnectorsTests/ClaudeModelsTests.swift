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

    // MARK: - claude 自己报的列表

    /// `initialize` 应答里的 `models`，照 2.1.318 的真实形状删短了：`default`、别名、带版本的、不能调强度的，
    /// 外加协议写不下的 `opus[1m]` 与一条重复的。
    private static let initializeAnswer: String = {
        let efforts = #""supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]"#
        let models = [
            #"{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)",\#(efforts)}"#,
            #"{"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5",\#(efforts)}"#,
            #"{"value":"claude-fable-5-2","resolvedModel":"claude-fable-5-2","displayName":"Fable 5.2",\#(efforts)}"#,
            #"{"value":"fable","resolvedModel":"claude-fable-5-1","displayName":"Fable 5.1",\#(efforts)}"#,
            #"{"value":"opus[1m]","resolvedModel":"claude-opus-5-5[1m]","displayName":"Opus 5.5 (1M context)",\#(efforts)}"#,
            #"{"value":"claude-haiku-4-5-20251001","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5","supportsThinkingOff":true}"#,
            #"{"value":"claude-fable-5","resolvedModel":"claude-fable-5","displayName":"Fable 5","supportsEffort":true,"supportedEffortLevels":["low","medium","high","max"]}"#,
            #"{"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5 again"}"#,
        ].joined(separator: ",")
        return #"{"type":"control_response","response":{"subtype":"success","request_id":"botbus-models","response":{"commands":[],"models":[\#(models)],"pid":1}}}"#
    }()

    private static var listedModels: [ClaudeListedModel] {
        ClaudeModels.initializeModels(inLine: Data(initializeAnswer.utf8)) ?? []
    }

    func testListedModelsComeFromTheInitializeAnswer() throws {
        let listed = try XCTUnwrap(ClaudeModels.initializeModels(inLine: Data(Self.initializeAnswer.utf8)))
        XCTAssertEqual(listed.map(\.option.id),
                       ["opus", "claude-fable-5-2", "fable", "claude-haiku-4-5-20251001", "claude-fable-5"],
                       "default 不收，方括号的 id 协议写不下，重复的只留第一个")
        XCTAssertEqual(listed.map(\.option.displayName), ["Opus 5.5", "Fable 5.2", "Fable 5.1", "Haiku 4.5", "Fable 5"])
        XCTAssertEqual(listed[0].option.efforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertNil(listed[3].option.efforts, "没说 supportsEffort 的不能调强度")
        XCTAssertEqual(listed[4].option.efforts, ["low", "medium", "high", "max"], "各模型的档位各算各的")
        XCTAssertEqual(listed[2].resolved, "claude-fable-5-1", "别名现在指向哪个模型")
        // 报出去之前还要过注册表的清洗：这份列表本身就是干净的。
        XCTAssertEqual(ConnectorRegistry.sanitized(listed.map(\.option)), listed.map(\.option))

        // 别的行不是应答；老版本的应答里没有 models，是空的（不用再等）。
        XCTAssertNil(ClaudeModels.initializeModels(inLine: Data(#"{"type":"system","subtype":"hook_started"}"#.utf8)))
        XCTAssertNil(ClaudeModels.initializeModels(inLine: Data(
            #"{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{"models":[]}}}"#.utf8)))
        XCTAssertEqual(ClaudeModels.initializeModels(inLine: Data(
            #"{"type":"control_response","response":{"subtype":"success","request_id":"botbus-models","response":{"commands":[]}}}"#.utf8)), [])
        XCTAssertNil(ClaudeModels.initializeModels(inLine: Data("not json".utf8)))
    }

    func testTranscriptModelsMapToListedOptions() {
        let listed = Self.listedModels
        XCTAssertEqual(ClaudeModels.optionId(forTranscriptModel: "claude-opus-5-5", in: listed), "opus", "别名指着它")
        XCTAssertEqual(ClaudeModels.optionId(forTranscriptModel: "claude-opus-5-5[1m]", in: listed), "opus")
        XCTAssertEqual(ClaudeModels.optionId(forTranscriptModel: "claude-fable-5-1", in: listed), "fable")
        XCTAssertEqual(ClaudeModels.optionId(forTranscriptModel: "claude-fable-5-2", in: listed), "claude-fable-5-2")
        XCTAssertEqual(ClaudeModels.optionId(forTranscriptModel: "claude-fable-5", in: listed), "claude-fable-5")
        XCTAssertNil(ClaudeModels.optionId(forTranscriptModel: "claude-opus-4-1", in: listed), "列表里没有的不硬说成 Opus")
        XCTAssertNil(ClaudeModels.optionId(forTranscriptModel: "<synthetic>", in: listed))
    }

    /// 假的 `claude`：记下参数、设置文件与 stdin 的第一行，先吐一行 hook 事件再答 `initialize`，然后等 stdin 关。
    private func fakeClaudeAnsweringInitialize(_ body: String? = nil) throws -> URL {
        try skipPOSIXScriptOnWindows()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("claude")
        try Self.initializeAnswer.write(to: directory.appendingPathComponent("answer"), atomically: true, encoding: .utf8)
        let script = body ?? """
        #!/bin/sh
        here=$(dirname "$0")
        printf '%s\\n' "$@" > "$here/args"
        while [ $# -gt 0 ]; do
          if [ "$1" = "--settings" ]; then cat "$2" > "$here/settings"; fi
          shift
        done
        IFS= read -r line
        printf '%s\\n' "$line" > "$here/stdin"
        printf '%s\\n' '{"type":"system","subtype":"hook_started"}'
        cat "$here/answer"
        printf '\\n'
        cat > /dev/null
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return binary
    }

    func testListAsksTheCLIWithHooksDisabled() async throws {
        let binary = try fakeClaudeAnsweringInitialize()
        let directory = binary.deletingLastPathComponent()
        let listed = await ClaudeModels.list(binary: binary.path, timeout: 10)
        XCTAssertEqual(listed?.map(\.option.id),
                       ["opus", "claude-fable-5-2", "fable", "claude-haiku-4-5-20251001", "claude-fable-5"])

        let arguments = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(arguments.prefix(7)),
                       ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--settings"])
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("settings"), encoding: .utf8),
                       #"{"disableAllHooks":true}"#, "探测不该触发用户的 SessionStart / SessionEnd hook")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(arguments.last)), "临时设置文件用完就删")
        let request = try String(contentsOf: directory.appendingPathComponent("stdin"), encoding: .utf8)
        XCTAssertTrue(request.contains(#""subtype":"initialize""#) && request.contains(#""request_id":"botbus-models""#))
    }

    func testListGivesUpWhenTheCLIDoesNotAnswer() async throws {
        // 没答就退出（没登录、不认这些参数）。
        let quitter = try fakeClaudeAnsweringInitialize("#!/bin/sh\nexit 1\n")
        let none = await ClaudeModels.list(binary: quitter.path, timeout: 10)
        XCTAssertNil(none)
        // 一直不答：到点放弃，进程被终止。
        let silent = try fakeClaudeAnsweringInitialize("#!/bin/sh\nexec sleep 30\n")
        let started = Date()
        let timedOut = await ClaudeModels.list(binary: silent.path, timeout: 0.3)
        XCTAssertNil(timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        // 连 SIGTERM 都不理：`list` 等它退出才返回，所以到点得强制结束它。
        let stubborn = try fakeClaudeAnsweringInitialize("#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 0.1; done\n")
        let stubbornStarted = Date()
        let killed = await ClaudeModels.list(binary: stubborn.path, timeout: 0.3, exitGrace: 0.3)
        XCTAssertNil(killed)
        XCTAssertLessThan(Date().timeIntervalSince(stubbornStarted), 10)
        // 起不来。
        let missing = await ClaudeModels.list(binary: "/nonexistent/claude", timeout: 1)
        XCTAssertNil(missing)
    }

    private func helpOnlyClaude() throws -> String {
        try skipPOSIXScriptOnWindows()
        let binary = FileManager.default.temporaryDirectory.appendingPathComponent("claude-help-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: binary) }
        try "#!/bin/sh\nprintf '%s\\n' '  --effort <level>  Effort level (low, medium, high, xhigh, max)'\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return binary.path
    }

    private func startError(_ connector: ClaudeConnector, _ selection: ModelSelection) async -> String {
        do {
            // 项目目录不存在：过了模型校验也起不来，报的是目录的错。
            _ = try await connector.start(projectPath: "/nonexistent/botbus-\(UUID().uuidString)", prompt: "hi", images: [],
                                          selection: selection)
            return ""
        } catch {
            return (error as? ConnectorError)?.message ?? String(describing: error)
        }
    }

    /// 问到列表之后：报给手机的换成 claude 自己那份，会话上显示的模型按 transcript 里的完整名字重新对一遍，
    /// 带版本的模型（Fable 5）能选，强度按各模型自己的档位校验。
    func testConnectorReportsListedModelsAndRemapsSessions() async throws {
        let binary = try helpOnlyClaude()
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1", name: "本机", appVersion: "1.0"))
        let listed = Self.listedModels
        let connector = ClaudeConnector(store: store, paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { binary }, modelLister: { _ in listed })
        XCTAssertEqual(store.connectors.models(for: .claude)?.map(\.id), ["fable", "opus", "sonnet", "haiku"], "还没问：写死的别名")

        let transcript = FileManager.default.temporaryDirectory.appendingPathComponent("claude-models-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: transcript) }
        try #"{"type":"assistant","message":{"model":"claude-fable-5","content":[{"type":"text","text":"好"}]}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let hook: [String: Any] = ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/p", "transcript_path": transcript.path]
        _ = await connector.handleHook(LocalHookServer.Request(method: "POST", target: "/hooks/claude", path: "/hooks/claude",
                                                               headers: ["content-type": "application/json"],
                                                               body: try JSONSerialization.data(withJSONObject: hook)))
        let before = await store.task(id: "claude:s1")
        XCTAssertEqual(before?.model, "fable", "只有别名时，Fable 5 只能说成 fable")

        await connector.refreshModels()
        XCTAssertEqual(store.connectors.models(for: .claude), listed.map(\.option))
        let after = await store.task(id: "claude:s1")
        XCTAssertEqual(after?.model, "claude-fable-5", "列表换了，会话上的模型跟着换成带版本的那一项")

        let accepted = await startError(connector, ModelSelection(model: "claude-fable-5", effort: "max"))
        XCTAssertFalse(accepted.contains("这个模型") || accepted.contains("思考强度"), "过了模型校验：\(accepted)")
        let wrongEffort = await startError(connector, ModelSelection(model: "claude-fable-5", effort: "xhigh"))
        XCTAssertTrue(wrongEffort.contains("没有「xhigh」这档思考强度"), wrongEffort)
        let fixedEffort = await startError(connector, ModelSelection(model: "claude-haiku-4-5-20251001", effort: "high"))
        XCTAssertTrue(fixedEffort.contains("不能调思考强度"), fixedEffort)
    }

    /// 选的模型不在手头的列表里：刚问过就直接拒，过了一会儿再来就现问一次；列表过期了在后台重问。
    func testUnknownModelTriggersAFreshListing() async throws {
        let binary = try helpOnlyClaude()
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1", name: "本机", appVersion: "1.0"))
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let answers = Locked<[ClaudeListedModel]?>(Array(Self.listedModels.prefix(1)))
        let asked = Locked(0)
        let connector = ClaudeConnector(store: store, paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { binary }, now: { clock.current },
                                        modelLister: { _ in
                                            asked.withLock { $0 += 1 }
                                            return answers.current
                                        })
        await connector.refreshModels()
        XCTAssertEqual(store.connectors.models(for: .claude)?.map(\.id), ["opus"])
        XCTAssertEqual(asked.current, 1)

        let rejected = await startError(connector, ModelSelection(model: "claude-fable-5"))
        XCTAssertTrue(rejected.contains("没有「claude-fable-5」这个模型"), rejected)
        XCTAssertEqual(asked.current, 1, "刚问过，不为同一个答案再等一次")

        // Claude Code 新上了模型：过一会儿再选，现问一次就认得了。
        answers.withLock { $0 = Self.listedModels }
        clock.withLock { $0 += ClaudeConnector.modelListRetryInterval + 1 }
        let accepted = await startError(connector, ModelSelection(model: "claude-fable-5"))
        XCTAssertFalse(accepted.contains("这个模型"), accepted)
        XCTAssertEqual(asked.current, 2)
        XCTAssertEqual(store.connectors.models(for: .claude)?.count, Self.listedModels.count)

        // 这次没问到（超时）：之前问到的留着。
        answers.withLock { $0 = nil }
        clock.withLock { $0 += ClaudeConnector.modelListTTL + 1 }
        _ = await startError(connector, ModelSelection(model: "opus"))
        let reasked = await eventually { asked.current == 3 }
        XCTAssertTrue(reasked, "列表过期了，在后台重问")
        await connector.refreshModels()
        XCTAssertEqual(store.connectors.models(for: .claude)?.count, Self.listedModels.count)
    }
}
