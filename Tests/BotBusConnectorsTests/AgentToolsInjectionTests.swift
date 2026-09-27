import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 手机任务的 agent 工具注入（spec 3.2）：说明文字、Claude 命令行、MCP 配置，以及真的起一个假 `claude` 看参数与环境。
final class AgentToolsInjectionTests: XCTestCase {
    private let cliPath = "/Applications/BotBus.app/Contents/Helpers/botbus"

    private func injection(token: String = "tok-123") -> AgentToolsInjection {
        AgentToolsInjection(configuration: AgentToolsConfiguration(cliPath: cliPath, toolsURL: "http://127.0.0.1:4567"),
                            token: token)
    }

    private func tempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func executable(_ name: String, in directory: URL, script: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - 纯函数

    func testInstructionsInterpolateCLIPath() {
        let text = AgentToolsInstructions.text(cliPath: cliPath)
        XCTAssertTrue(text.hasPrefix("This task was sent from the user's phone through BotBus."))
        XCTAssertTrue(text.contains("or the CLI at `\(cliPath)`"))
        XCTAssertTrue(text.contains("`share_preview`"))
        XCTAssertTrue(text.contains("`share_file`"))
        XCTAssertTrue(text.contains("Keep your final answer short; the user reads it on a phone."))
    }

    func testEnvironmentAndMCPConfig() throws {
        let value = injection()
        XCTAssertEqual(value.environment, ["BOTBUS_TOOLS_URL": "http://127.0.0.1:4567",
                                           "BOTBUS_TASK_TOKEN": "tok-123",
                                           "BOTBUS_CLI": cliPath])
        let parsed = try JSONSerialization.jsonObject(with: Data(value.mcpConfigJSON().utf8)) as? [String: Any]
        let server = try XCTUnwrap((parsed?["mcpServers"] as? [String: Any])?["botbus"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, cliPath)
        XCTAssertEqual(server["args"] as? [String], ["mcp"])
        XCTAssertEqual(server["env"] as? [String: String], value.environment)
        XCTAssertFalse(value.mcpConfigJSON().contains("\\/"), "路径不转义斜杠，便于人读")
    }

    func testMakeRequiresUsableConfigurationAndReusesTokens() async throws {
        let registry = TaskContextRegistry()
        let none = await AgentToolsInjection.make(nil, registry: registry)
        XCTAssertNil(none)
        let missing = await AgentToolsInjection.make(AgentToolsConfiguration(cliPath: "/nonexistent/botbus",
                                                                             toolsURL: "http://127.0.0.1:1"),
                                                     registry: registry)
        XCTAssertNil(missing, "开发环境没嵌 CLI：完全不注入")
        let noURL = await AgentToolsInjection.make(AgentToolsConfiguration(cliPath: "/bin/sh", toolsURL: ""),
                                                   registry: registry)
        XCTAssertNil(noURL)

        let usable = AgentToolsConfiguration(cliPath: "/bin/sh", toolsURL: "http://127.0.0.1:1")
        let made = await AgentToolsInjection.make(usable, registry: registry, reusing: "claude:s1")
        let fresh = try XCTUnwrap(made)
        await registry.bind(fresh.token, taskId: "claude:s1")
        let reused = await AgentToolsInjection.make(usable, registry: registry, reusing: "claude:s1")
        XCTAssertEqual(reused?.token, fresh.token)
    }

    // MARK: - Claude 命令行

    func testClaudeArgumentsWithoutInjectionAreUnchanged() {
        XCTAssertEqual(ClaudeConnector.arguments(prompt: "做个页面", resuming: nil, injection: nil),
                       ["-p", "做个页面", "--output-format", "stream-json", "--verbose"])
        XCTAssertEqual(ClaudeConnector.arguments(prompt: "接着改", resuming: "s1", injection: nil),
                       ["-p", "--resume", "s1", "接着改", "--output-format", "stream-json", "--verbose"])
    }

    /// `--mcp-config` / `--allowedTools` 是可变参数：必须排在 prompt 之后，并被下一个 `--flag` 收尾。
    func testClaudeArgumentOrderKeepsVariadicFlagsAfterPromptAndTerminated() throws {
        let value = injection()
        let arguments = ClaudeConnector.arguments(prompt: "做个页面", resuming: "s1", injection: value)
        XCTAssertEqual(Array(arguments.prefix(4)), ["-p", "--resume", "s1", "做个页面"])
        let prompt = try XCTUnwrap(arguments.firstIndex(of: "做个页面"))
        let append = try XCTUnwrap(arguments.firstIndex(of: "--append-system-prompt"))
        let mcp = try XCTUnwrap(arguments.firstIndex(of: "--mcp-config"))
        let allowed = try XCTUnwrap(arguments.firstIndex(of: "--allowedTools"))
        let output = try XCTUnwrap(arguments.firstIndex(of: "--output-format"))
        XCTAssertLessThan(prompt, append)
        XCTAssertEqual(arguments[append + 1], value.instructions)
        XCTAssertEqual(arguments[mcp + 1], value.mcpConfigJSON())
        XCTAssertEqual(arguments[allowed + 1], "mcp__botbus")
        XCTAssertEqual(output, allowed + 2, "--allowedTools 的值后面紧跟一个 --flag 收尾")
        XCTAssertEqual(Array(arguments.suffix(3)), ["--output-format", "stream-json", "--verbose"])
    }

    func testClaudeEnvironmentMergesOverInherited() {
        XCTAssertEqual(ClaudeConnector.environment(adding: [:], to: ["PATH": "/usr/bin", "HOME": "/Users/me"]),
                       ["PATH": "/usr/bin", "HOME": "/Users/me"], "没有注入就原样继承")
        let merged = ClaudeConnector.environment(adding: ["BOTBUS_TASK_TOKEN": "new"],
                                                 to: ["PATH": "/usr/bin", "BOTBUS_TASK_TOKEN": "stale"])
        XCTAssertEqual(merged, ["PATH": "/usr/bin", "BOTBUS_TASK_TOKEN": "new"])
    }

    // MARK: - 起一个假 claude

    /// 假 `claude`：把参数（NUL 分隔）与三个环境变量写进文件，吐一行 init 与一行 result。
    /// 带 `--resume` 时报一个新的 session id，模拟桌面会话被分支。
    /// 带 `--input-format`（发图）时把 stdin 读到 EOF 存进文件：连接器必须写完并关闭 stdin，否则这里一直卡着拿不到 init。
    /// 末尾停一会儿再退：真的 claude 一轮要跑好几秒，连接器在进程退出时若还没读到 init 行就判它失败，
    /// 立刻退出的假进程会和 stdout 的读取抢跑。
    private func fakeClaude(in directory: URL) throws -> URL {
        let record = directory.path
        return try executable("claude", in: directory, script: """
        #!/bin/sh
        sid="sess-1"
        for a in "$@"; do [ "$a" = "--resume" ] && sid="fork-1"; done
        for a in "$@"; do printf '%s\\0' "$a"; done > "\(record)/$sid.args"
        printf '%s\\n%s\\n%s\\n' "$BOTBUS_TOOLS_URL" "$BOTBUS_TASK_TOKEN" "$BOTBUS_CLI" > "\(record)/$sid.env"
        printf '%s' "$HOME" > "\(record)/$sid.home"
        for a in "$@"; do [ "$a" = "--input-format" ] && cat > "\(record)/$sid.stdin"; done
        echo '{"type":"system","subtype":"init","session_id":"'"$sid"'"}'
        echo '{"type":"result","subtype":"success","result":"done"}'
        sleep 0.5
        """)
    }

    private func makeClaudeStore() -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                  connectors: ConnectorRegistry(descriptors: [
                      ConnectorDescriptor(kind: .claude, displayName: "Claude Code", defaultEnabled: true) {
                          ConnectorProbe(available: true, status: .ok)
                      },
                  ]))
    }

    private func recorded(_ directory: URL, _ sid: String) throws -> (arguments: [String], environment: [String]) {
        let args = try Data(contentsOf: directory.appendingPathComponent("\(sid).args"))
        let env = try String(contentsOf: directory.appendingPathComponent("\(sid).env"), encoding: .utf8)
        let arguments = args.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
            String(decoding: $0, as: UTF8.self)
        }
        return (Array(arguments), Array(env.components(separatedBy: "\n").dropLast()))
    }

    func testClaudeStartInjectsToolsAndBindsSessionThenFollowUpForkReusesToken() async throws {
        let directory = try tempDirectory()
        let project = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let claude = try fakeClaude(in: directory)
        let cli = try executable("botbus", in: directory, script: "#!/bin/sh\nexit 0\n")
        let registry = TaskContextRegistry()
        let configuration = AgentToolsConfiguration(cliPath: cli.path, toolsURL: "http://127.0.0.1:4567")
        let store = makeClaudeStore()
        let connector = ClaudeConnector(store: store,
                                        paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { claude.path }, tools: { configuration }, registry: registry)

        let outcome = try await connector.start(projectPath: project.path, prompt: "做个落地页")
        XCTAssertEqual(outcome.taskId, "sess-1")
        let first = try recorded(directory, "sess-1")
        XCTAssertEqual(first.environment, ["http://127.0.0.1:4567", first.environment[1], cli.path])
        let token = first.environment[1]
        XCTAssertFalse(token.isEmpty)
        let bound = await registry.resolve(token, wait: 0)
        XCTAssertEqual(bound, "claude:sess-1")
        XCTAssertEqual(first.arguments, ClaudeConnector.arguments(
            prompt: "做个落地页", resuming: nil,
            injection: AgentToolsInjection(configuration: configuration, token: token)))

        // 等这一轮跑完再续聊：还在跑时的续聊会排队（见 ClaudeFollowUpQueueTests）。
        await assertEventually(timeout: 5) { await store.task(id: "claude:sess-1")?.status == .completed }
        // 续聊分支出新 session：同一个 token 改绑到新 id。
        let branched = try await connector.followUp(taskId: "claude:sess-1", prompt: "改成深色")
        XCTAssertEqual(branched.taskId, "fork-1")
        let second = try recorded(directory, "fork-1")
        XCTAssertEqual(second.environment[1], token)
        XCTAssertEqual(Array(second.arguments.prefix(4)), ["-p", "--resume", "sess-1", "改成深色"])
        let rebound = await registry.resolve(token, wait: 0)
        XCTAssertEqual(rebound, "claude:fork-1")
        await connector.stop()
    }

    func testClaudeWithoutToolsInheritsEnvironmentUntouched() async throws {
        let directory = try tempDirectory()
        let claude = try fakeClaude(in: directory)
        let connector = ClaudeConnector(store: makeClaudeStore(),
                                        paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { claude.path })
        _ = try await connector.start(projectPath: directory.path, prompt: "hi")
        let recorded = try recorded(directory, "sess-1")
        XCTAssertEqual(recorded.arguments, ["-p", "hi", "--output-format", "stream-json", "--verbose"])
        XCTAssertEqual(recorded.environment[1], ProcessInfo.processInfo.environment["BOTBUS_TASK_TOKEN"] ?? "")
        // 空环境的 claude 找不到 HOME 下的登录态，只会回 "Not logged in"。
        let home = try String(contentsOf: directory.appendingPathComponent("sess-1.home"), encoding: .utf8)
        XCTAssertEqual(home, ProcessInfo.processInfo.environment["HOME"])
        await connector.stop()
    }

    // MARK: - Claude 发图（协议 2.9）

    func testClaudeStreamingArgumentsDropPositionalPromptAndTerminateVariadicFlags() throws {
        XCTAssertEqual(ClaudeConnector.arguments(prompt: "看图", resuming: nil, injection: nil, streamingInput: true),
                       ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"])
        let value = injection()
        let arguments = ClaudeConnector.arguments(prompt: "看图", resuming: "s1", injection: value, streamingInput: true)
        XCTAssertFalse(arguments.contains("看图"), "prompt 走 stdin，不再是位置参数")
        XCTAssertEqual(Array(arguments.prefix(3)), ["-p", "--resume", "s1"])
        XCTAssertEqual(Array(arguments[3..<(3 + value.claudeArguments().count)]), value.claudeArguments())
        let allowed = try XCTUnwrap(arguments.firstIndex(of: "--allowedTools"))
        XCTAssertEqual(arguments[allowed + 2], "--input-format", "--allowedTools 的值后面紧跟一个 --flag 收尾")
        XCTAssertEqual(Array(arguments.suffix(5)),
                       ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose"])
        // 不发图：与以前逐项相等。
        XCTAssertEqual(ClaudeConnector.arguments(prompt: "做个页面", resuming: "s1", injection: value, streamingInput: false),
                       ClaudeConnector.arguments(prompt: "做个页面", resuming: "s1", injection: value))
        XCTAssertEqual(ClaudeConnector.arguments(prompt: "做个页面", resuming: "s1", injection: value),
                       ["-p", "--resume", "s1", "做个页面"] + value.claudeArguments()
                       + ["--output-format", "stream-json", "--verbose"])
    }

    func testClaudeStdinPayloadIsOneUserLineWithImagesThenText() throws {
        let data = try ClaudeConnector.stdinPayload(prompt: "这是什么", images: [
            (data: Data([1, 2, 3]), contentType: "image/png"),
            (data: Data([4, 5]), contentType: "image/jpeg"),
        ])
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1, "只有一行")
        let line = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(line["type"] as? String, "user")
        let message = try XCTUnwrap(line["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "image", "text"])
        XCTAssertEqual(content[0]["source"] as? [String: String],
                       ["type": "base64", "media_type": "image/png", "data": Data([1, 2, 3]).base64EncodedString()])
        XCTAssertEqual((content[1]["source"] as? [String: String])?["media_type"], "image/jpeg")
        XCTAssertEqual(content[2]["text"] as? String, "这是什么")

        let imageOnly = try ClaudeConnector.stdinPayload(prompt: "", images: [(data: Data([1]), contentType: "image/gif")])
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: imageOnly) as? [String: Any])
        let only = try XCTUnwrap((parsed["message"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(only.map { $0["type"] as? String }, ["image"], "没有字就不放 text 块")
    }

    func testClaudeImageMediaTypeFollowsExtension() {
        let cases = ["a.jpg": "image/jpeg", "a.JPEG": "image/jpeg", "a.png": "image/png",
                     "a.heic": "image/heic", "a.webp": "image/webp", "a.gif": "image/gif"]
        for (name, expected) in cases {
            XCTAssertEqual(ClaudeConnector.mediaType(for: URL(fileURLWithPath: "/tmp/\(name)")), expected, name)
        }
    }

    func testClaudeStartWithImagesWritesPayloadToStdinAndCloses() async throws {
        let directory = try tempDirectory()
        let claude = try fakeClaude(in: directory)
        // 一张大图：几 MB 的 stdin 远超管道缓冲，写入若卡在 actor 上或忘了关闭，这里会超时。
        let big = directory.appendingPathComponent("big.png")
        try Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: big)
        let small = directory.appendingPathComponent("small.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: small)
        let connector = ClaudeConnector(store: makeClaudeStore(),
                                        paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { claude.path })

        let outcome = try await connector.start(projectPath: directory.path, prompt: "看图", images: [big, small])
        XCTAssertEqual(outcome.taskId, "sess-1")
        let recorded = try recorded(directory, "sess-1")
        XCTAssertEqual(recorded.arguments, ClaudeConnector.arguments(prompt: "看图", resuming: nil, injection: nil,
                                                                     streamingInput: true))
        let stdin = try Data(contentsOf: directory.appendingPathComponent("sess-1.stdin"))
        let expected = try ClaudeConnector.stdinPayload(prompt: "看图", images: [
            (data: try Data(contentsOf: big), contentType: "image/png"),
            (data: try Data(contentsOf: small), contentType: "image/jpeg"),
        ])
        XCTAssertEqual(stdin, expected)
        await connector.stop()
    }

    /// 只发图新建任务：标题记「图片」（与 Codex 一致），不能是空串。
    func testClaudeImageOnlyStartTitlesTheTaskImage() async throws {
        let directory = try tempDirectory()
        let claude = try fakeClaude(in: directory)
        let image = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let store = makeClaudeStore()
        let connector = ClaudeConnector(store: store,
                                        paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { claude.path })

        _ = try await connector.start(projectPath: directory.path, prompt: "  \n", images: [image])
        let title = await store.task(id: "claude:sess-1")?.title
        XCTAssertEqual(title, "图片")
        await connector.stop()
    }

    func testClaudePromptTitleKeepsPlaceholderWhenPromptIsBlank() {
        let session = { ClaudeConnector.Session(sessionID: "s", projectPath: "/p/demo", title: "demo",
                                                titleSource: .placeholder, status: .running, origin: .watch,
                                                startedAt: "2026-09-25T00:00:00Z", updatedAt: "2026-09-25T00:00:00Z") }
        var withText = session()
        ClaudeConnector.applyPromptTitle(&withText, prompt: "  修一下登录 ", hasImages: true)
        XCTAssertEqual(withText.title, "修一下登录")
        XCTAssertEqual(withText.titleSource, .prompt)

        var imageOnly = session()
        ClaudeConnector.applyPromptTitle(&imageOnly, prompt: " ", hasImages: true)
        XCTAssertEqual(imageOnly.title, "图片")
        XCTAssertEqual(imageOnly.titleSource, .placeholder, "之后带字的 prompt 还能换掉它")

        var blank = session()
        ClaudeConnector.applyPromptTitle(&blank, prompt: "", hasImages: false)
        XCTAssertEqual(blank.title, "demo", "没字也没图时留着项目名占位")
        XCTAssertEqual(blank.titleSource, .placeholder)
    }

    func testClaudeFollowUpWithUnreadableImageFailsBeforeLaunching() async throws {
        let directory = try tempDirectory()
        let claude = try fakeClaude(in: directory)
        let connector = ClaudeConnector(store: makeClaudeStore(),
                                        paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { claude.path })
        do {
            _ = try await connector.followUp(taskId: "claude:s1", prompt: "",
                                             images: [directory.appendingPathComponent("missing.jpg")])
            XCTFail("图读不到不能起进程")
        } catch let error as ConnectorError {
            XCTAssertEqual(error.message, "读不到要发送的图片")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("fork-1.args").path))
        await connector.stop()
    }
}
