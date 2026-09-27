import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 假的 `pi` 进程：测试往 stdout 塞 JSON 行、决定何时以什么退出码退出，并记录收到的信号。
final class FakePiProcess: PiProcessHandle, @unchecked Sendable {
    let request: PiLaunchRequest
    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void
    let interrupts = Locked(0)
    let terminations = Locked(0)
    private let exited = Locked(false)

    init(request: PiLaunchRequest, onOutput: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) {
        self.request = request
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func emit(_ object: [String: Any]) {
        onOutput(Data((PiFixture.line(object) + "\n").utf8))
    }

    /// 故意把一行拆成两块送：真实管道不保证按行到达。
    func emitSplit(_ object: [String: Any]) {
        let line = Data((PiFixture.line(object) + "\n").utf8)
        let middle = line.count / 2
        onOutput(line.prefix(middle))
        onOutput(line.suffix(from: middle))
    }

    /// 不带换行的半行：进程退出时缓冲里剩下的那种。
    func emitWithoutNewline(_ object: [String: Any]) {
        onOutput(Data(PiFixture.line(object).utf8))
    }

    func exit(_ status: Int32) {
        let first = exited.withLock { value -> Bool in
            defer { value = true }
            return !value
        }
        if first { onExit(status) }
    }

    func interrupt() { interrupts.withLock { $0 += 1 } }
    func terminate() { terminations.withLock { $0 += 1 } }
}

final class FakePiLauncher: PiProcessLauncher, @unchecked Sendable {
    /// 在 `launch` 返回之前同步调用：用来模拟"header 立刻就到"甚至"一轮在登记前就跑完了"。
    let onLaunch: Locked<(@Sendable (FakePiProcess) -> Void)?>
    let processes = Locked<[FakePiProcess]>([])

    init(onLaunch: (@Sendable (FakePiProcess) -> Void)? = nil) {
        self.onLaunch = Locked(onLaunch)
    }

    var last: FakePiProcess? { processes.current.last }

    func launch(_ request: PiLaunchRequest, onOutput: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws -> any PiProcessHandle {
        let process = FakePiProcess(request: request, onOutput: onOutput, onExit: onExit)
        processes.withLock { $0.append(process) }
        onLaunch.current?(process)
        return process
    }

    /// 标准剧本：一启动就吐 header。
    static func emittingHeader(id: String, cwd: String = "/p") -> FakePiLauncher {
        FakePiLauncher { process in process.emit(PiFixture.header(id: id, cwd: cwd)) }
    }
}

final class PiConnectorTests: XCTestCase {
    private var fixture: PiFixture!
    private var projectDirectory: URL!

    override func setUpWithError() throws {
        fixture = try PiFixture()
        projectDirectory = fixture.agentDirectory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() { fixture.remove() }

    private func makeStore() -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                  connectors: ConnectorRegistry(descriptors: [
                      ConnectorDescriptor(kind: .pi, displayName: "Pi", defaultEnabled: true) {
                          ConnectorProbe(available: true, status: .ok)
                      },
                  ]))
    }

    private func makeConnector(store: TaskStore, launcher: FakePiLauncher,
                               tools: AgentToolsConfiguration? = nil,
                               registry: TaskContextRegistry = TaskContextRegistry(),
                               finished: Locked<Int> = Locked(0)) -> PiConnector {
        let paths = fixture.paths
        return PiConnector(store: store, paths: { paths }, binary: { "/fake/bin/pi" }, launcher: launcher,
                           tools: { tools }, registry: registry,
                           onRunFinished: { finished.withLock { $0 += 1 } })
    }

    private static func assistantEnd(_ text: String, stop: String = "stop", extra: [String: Any] = [:]) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": text]], "stopReason": stop]
        message.merge(extra) { _, new in new }
        return ["type": "message_end", "message": message]
    }

    // MARK: - start

    func testStartReturnsSessionIdClaimsLiveAndPublishesRunning() async throws {
        let store = makeStore()
        let launcher = FakePiLauncher.emittingHeader(id: "0199-new")
        let connector = makeConnector(store: store, launcher: launcher)

        let outcome = try await connector.start(projectPath: projectDirectory.path, prompt: "给首页加个深色模式")
        XCTAssertEqual(outcome.taskId, "pi:0199-new")
        XCTAssertTrue(outcome.retainsLiveOwnership, "一轮还在跑，所有权不能跟着回执交还")

        let owner = await store.owner(of: "pi:0199-new")
        XCTAssertEqual(owner, .live)
        let task = try await XCTUnwrapAsync(await store.task(id: "pi:0199-new"))
        XCTAssertEqual(task.status, .running)
        XCTAssertEqual(task.origin, .watch)
        XCTAssertEqual(task.source, .pi)
        XCTAssertEqual(task.title, "给首页加个深色模式")
        XCTAssertEqual(task.projectPath, projectDirectory.path)
        XCTAssertTrue(task.controllable)

        let request = try XCTUnwrap(launcher.last?.request)
        XCTAssertEqual(request.executable, "/fake/bin/pi")
        XCTAssertEqual(request.arguments, ["--mode", "json", "给首页加个深色模式"])
        XCTAssertEqual(request.workingDirectory, projectDirectory.path, "pi 没有 --cwd，靠子进程的工作目录")
        XCTAssertTrue(request.environment["PATH"]?.hasPrefix("/fake/bin:") ?? false,
                      "pi 是 node 脚本，可执行文件所在目录要排在 PATH 最前")
        XCTAssertNil(request.environment[AgentToolsInjection.taskTokenVariable], "没配工具就完全不注入")
    }

    func testFinishWritesCompletedReleasesOwnershipAndPokesObserver() async throws {
        let store = makeStore()
        let launcher = FakePiLauncher.emittingHeader(id: "s1")
        let finished = Locked(0)
        let connector = makeConnector(store: store, launcher: launcher, finished: finished)
        _ = try await connector.start(projectPath: projectDirectory.path, prompt: "跑一下测试")
        let process = try XCTUnwrap(launcher.last)

        process.emit(["type": "agent_start"])
        process.emitSplit(Self.assistantEnd("中间的话", stop: "toolUse"))
        process.emit(["type": "tool_execution_start", "toolName": "bash"])
        process.emitSplit(Self.assistantEnd("测试都过了。"))
        process.emit(["type": "agent_end", "messages": []])
        process.emit(["type": "agent_settled"])

        await assertEventually { await store.task(id: "pi:s1")?.status == .completed }
        let task = await store.task(id: "pi:s1")
        XCTAssertEqual(task?.lastMessage, "测试都过了。")
        await assertEventually { await store.owner(of: "pi:s1") == .observer }
        await assertEventually { finished.current == 1 }

        // 进程随后才退出：不能再收一次尾。
        process.exit(0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(finished.current, 1)
    }

    func testNonZeroExitMarksFailedWithErrorMessage() async throws {
        let store = makeStore()
        let launcher = FakePiLauncher.emittingHeader(id: "s1")
        let connector = makeConnector(store: store, launcher: launcher)
        _ = try await connector.start(projectPath: projectDirectory.path, prompt: "做点什么")
        let process = try XCTUnwrap(launcher.last)

        process.emit(["type": "message_end",
                      "message": ["role": "assistant", "content": [], "stopReason": "error",
                                  "errorMessage": "401 Unauthorized"]])
        process.exit(1)

        await assertEventually { await store.task(id: "pi:s1")?.status == .failed }
        let task = await store.task(id: "pi:s1")
        XCTAssertEqual(task?.lastMessage, "401 Unauthorized", "没有正文时把错误原因放上去")
        await assertEventually { await store.owner(of: "pi:s1") == .observer }
    }

    func testErrorStopReasonFailsEvenWithZeroExit() async throws {
        let store = makeStore()
        let launcher = FakePiLauncher.emittingHeader(id: "s1")
        let connector = makeConnector(store: store, launcher: launcher)
        _ = try await connector.start(projectPath: projectDirectory.path, prompt: "做点什么")
        let process = try XCTUnwrap(launcher.last)
        process.emitWithoutNewline(Self.assistantEnd("半截", stop: "error"))
        // 最后一行没带换行就退出了：也要读到。
        process.exit(0)
        await assertEventually { await store.task(id: "pi:s1")?.status == .failed }
    }

    func testExitBeforeHeaderFailsStart() async throws {
        let store = makeStore()
        let launcher = FakePiLauncher { process in process.exit(1) }
        let connector = makeConnector(store: store, launcher: launcher)
        do {
            _ = try await connector.start(projectPath: projectDirectory.path, prompt: "hi")
            XCTFail("没有 header 就退出，start 必须报错")
        } catch {
            XCTAssertTrue((error as? ConnectorError)?.message.contains("没有拿到会话 id") ?? false, "\(error)")
        }
    }

    func testStartRejectsMissingDirectoryAndMissingBinary() async throws {
        let store = makeStore()
        let launcher = FakePiLauncher.emittingHeader(id: "s1")
        let connector = makeConnector(store: store, launcher: launcher)
        do {
            _ = try await connector.start(projectPath: "/nonexistent/project", prompt: "hi")
            XCTFail("目录不存在应当报错")
        } catch {
            XCTAssertTrue((error as? ConnectorError)?.message.hasPrefix("项目目录不存在") ?? false)
        }
        let noBinary = PiConnector(store: store, binary: { nil }, launcher: launcher)
        do {
            _ = try await noBinary.start(projectPath: projectDirectory.path, prompt: "hi")
            XCTFail("没有 pi 应当报错")
        } catch {}
        XCTAssertTrue(launcher.processes.current.isEmpty)
    }

    /// 整轮在 `start` 登记完之前就跑完了（首行之后立刻报错退出）：最终状态不能被随后的 running 盖掉，
    /// 所有权也不能卡在 live——经分发器走一遍完整流程来看。
    func testRunFinishingBeforeRegistrationEndsCleanlyThroughDispatcher() async throws {
        let store = makeStore()
        let launcher = FakePiLauncher { process in
            process.emit(PiFixture.header(id: "fast", cwd: "/p"))
            process.emit(Self.assistantEnd("瞬间就完了"))
            process.emit(["type": "agent_settled"])
            process.exit(0)
        }
        let finished = Locked(0)
        let connector = makeConnector(store: store, launcher: launcher, finished: finished)
        let dispatcher = CommandDispatcher(store: store, connectors: [connector], readers: [])
        let result = await dispatcher.handle(.startTask(
            Command.StartTask(source: .pi, projectPath: projectDirectory.path, prompt: "快"),
            createdAt: "2026-09-24T00:00:00Z", agentId: "agent-1"))
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(result.taskId, "pi:fast")

        await assertEventually { await store.task(id: "pi:fast")?.status == .completed }
        await assertEventually { await store.owner(of: "pi:fast") == .observer }
        await assertEventually { finished.current == 1 }
        let task = await store.task(id: "pi:fast")
        XCTAssertEqual(task?.lastMessage, "瞬间就完了")
    }

    // MARK: - 注入

    func testInjectionAddsEnvironmentInstructionsAndBindsToken() async throws {
        let cli = fixture.agentDirectory.appendingPathComponent("botbus")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let tools = AgentToolsConfiguration(cliPath: cli.path, toolsURL: "http://127.0.0.1:4567")
        let registry = TaskContextRegistry()
        let store = makeStore()
        let launcher = FakePiLauncher.emittingHeader(id: "s1")
        let connector = makeConnector(store: store, launcher: launcher, tools: tools, registry: registry)

        _ = try await connector.start(projectPath: projectDirectory.path, prompt: "做个页面")
        let request = try XCTUnwrap(launcher.last?.request)
        let token = try XCTUnwrap(request.environment[AgentToolsInjection.taskTokenVariable])
        XCTAssertEqual(request.environment[AgentToolsInjection.toolsURLVariable], "http://127.0.0.1:4567")
        XCTAssertEqual(request.environment[AgentToolsInjection.cliVariable], cli.path)
        let injection = AgentToolsInjection(configuration: tools, token: token)
        XCTAssertEqual(request.arguments, ["--mode", "json", "--append-system-prompt", injection.cliOnlyInstructions, "做个页面"])
        XCTAssertFalse(injection.cliOnlyInstructions.contains("MCP"), "Pi 没有 MCP，说明文字不能提它")
        let bound = await registry.taskId(for: token)
        XCTAssertEqual(bound, "pi:s1")
    }

    func testArgumentsOrdering() {
        let injection = AgentToolsInjection(configuration: AgentToolsConfiguration(cliPath: "/x/botbus", toolsURL: "http://127.0.0.1:1"),
                                            token: "t")
        XCTAssertEqual(PiConnector.arguments(prompt: "继续", sessionFile: "/s/a_b.jsonl", injection: injection),
                       ["--mode", "json", "--session", "/s/a_b.jsonl", "--append-system-prompt",
                        injection.cliOnlyInstructions, "继续"])
        XCTAssertEqual(PiConnector.arguments(prompt: "继续", sessionFile: nil, injection: nil),
                       ["--mode", "json", "继续"])
        XCTAssertEqual(PiConnector.arguments(prompt: "-v 是什么", sessionFile: nil, injection: nil).last, " -v 是什么",
                       "以 - 开头的 prompt 不能被当成选项")
        XCTAssertEqual(PiConnector.arguments(prompt: "@README 看看", sessionFile: nil, injection: nil).last, " @README 看看",
                       "以 @ 开头的 prompt 不能被当成附带文件")
    }

    // MARK: - interrupt

    func testInterruptSignalsOwnProcessAndStaysInterrupted() async throws {
        let store = makeStore()
        let launcher = FakePiLauncher.emittingHeader(id: "s1")
        let finished = Locked(0)
        let connector = makeConnector(store: store, launcher: launcher, finished: finished)
        _ = try await connector.start(projectPath: projectDirectory.path, prompt: "长任务")
        let process = try XCTUnwrap(launcher.last)

        let outcome = try await connector.interrupt(taskId: "pi:s1")
        XCTAssertEqual(outcome.taskId, "pi:s1")
        XCTAssertTrue(outcome.retainsLiveOwnership, "进程退出时才交还")
        XCTAssertEqual(process.interrupts.current, 1)
        let interrupted = await store.task(id: "pi:s1")
        XCTAssertEqual(interrupted?.status, .interrupted)

        // SIGINT 之后以非 0 退出：不能被改成 failed。
        process.exit(130)
        await assertEventually { finished.current == 1 }
        let final = await store.task(id: "pi:s1")
        XCTAssertEqual(final?.status, .interrupted)
        let owner = await store.owner(of: "pi:s1")
        XCTAssertEqual(owner, .observer)
    }

    func testInterruptWithoutOwnProcessThrows() async {
        let connector = makeConnector(store: makeStore(), launcher: FakePiLauncher())
        do {
            _ = try await connector.interrupt(taskId: "pi:desktop")
            XCTFail("桌面上开的会话中断不了")
        } catch {
            XCTAssertEqual((error as? ConnectorError)?.message, "这个会话是在电脑上启动的，只能在电脑上中断")
        }
    }

    func testApproveAlwaysThrows() async {
        let connector = makeConnector(store: makeStore(), launcher: FakePiLauncher())
        do {
            _ = try await connector.approve(taskId: "pi:s1", requestId: "r", decision: .allow)
            XCTFail("Pi 没有审批")
        } catch {
            XCTAssertEqual((error as? ConnectorError)?.message, "Pi 没有审批机制，工具调用不需要批准")
        }
    }

    func testImagesAreRefusedWithoutLaunching() async throws {
        let launcher = FakePiLauncher()
        let connector = makeConnector(store: makeStore(), launcher: launcher)
        let image = [URL(fileURLWithPath: "/tmp/a.jpg")]
        for attempt in [
            { try await connector.start(projectPath: "/tmp", prompt: "看图", images: image) },
            { try await connector.followUp(taskId: "pi:s1", prompt: "看图", images: image) },
        ] as [@Sendable () async throws -> ConnectorOutcome] {
            do {
                _ = try await attempt()
                XCTFail("Pi 不支持发图")
            } catch {
                XCTAssertEqual((error as? ConnectorError)?.message, "这个 Agent 暂不支持发图")
            }
        }
        XCTAssertTrue(launcher.processes.current.isEmpty)
    }

    // MARK: - followUp

    func testFollowUpResumesBySessionFilePathInHeaderCwd() async throws {
        let file = try fixture.write(id: "0199-desk", lines: [
            PiFixture.header(id: "0199-desk", cwd: projectDirectory.path),
            PiFixture.user("u", parent: nil, "桌面上问的"),
            PiFixture.assistant("a", parent: "u", text: "桌面上答的"),
        ], modifiedAt: Date().addingTimeInterval(-600))
        let store = makeStore()
        // 观察者之前读到的样子。
        await store.upsert(TaskRecord(id: "pi:0199-desk", agentId: "agent-1", source: .pi, title: "桌面上问的",
                                      projectPath: projectDirectory.path, projectName: "project", status: .completed,
                                      lastMessage: "桌面上答的", origin: .desktop, controllable: true,
                                      startedAt: "2026-09-20T01:00:00Z", updatedAt: "2026-09-20T01:00:02Z"))
        let launcher = FakePiLauncher.emittingHeader(id: "0199-desk", cwd: projectDirectory.path)
        let connector = makeConnector(store: store, launcher: launcher)

        let outcome = try await connector.followUp(taskId: "pi:0199-desk", prompt: "再补个测试")
        XCTAssertEqual(outcome.taskId, "pi:0199-desk")
        XCTAssertTrue(outcome.retainsLiveOwnership)

        let request = try XCTUnwrap(launcher.last?.request)
        // 临时目录在 /var 与 /private/var 之间有软链接，比较前先解开。
        var arguments = request.arguments
        XCTAssertEqual(arguments.count, 5)
        let sessionPath = arguments.count == 5 ? arguments.remove(at: 3) : ""
        XCTAssertEqual(arguments, ["--mode", "json", "--session", "再补个测试"])
        XCTAssertTrue(sessionPath.hasPrefix("/"), "只传绝对路径，不传 id（传 id 可能弹 fork 确认把进程卡死）")
        XCTAssertEqual(URL(fileURLWithPath: sessionPath).resolvingSymlinksInPath().path,
                       file.resolvingSymlinksInPath().path)
        XCTAssertEqual(request.workingDirectory, projectDirectory.path, "工作目录以 header 的 cwd 为准")

        let task = await store.task(id: "pi:0199-desk")
        XCTAssertEqual(task?.status, .running)
        XCTAssertEqual(task?.title, "桌面上问的", "续聊不改标题")
        XCTAssertEqual(task?.origin, .desktop)
        let owner = await store.owner(of: "pi:0199-desk")
        XCTAssertEqual(owner, .live)

        launcher.last?.emit(Self.assistantEnd("补好了"))
        launcher.last?.exit(0)
        await assertEventually { await store.task(id: "pi:0199-desk")?.status == .completed }
        let done = await store.task(id: "pi:0199-desk")
        XCTAssertEqual(done?.lastMessage, "补好了")
    }

    func testFollowUpReusesToken() async throws {
        let cli = fixture.agentDirectory.appendingPathComponent("botbus")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let tools = AgentToolsConfiguration(cliPath: cli.path, toolsURL: "http://127.0.0.1:4567")
        let registry = TaskContextRegistry()
        let store = makeStore()
        let launcher = FakePiLauncher.emittingHeader(id: "s1", cwd: projectDirectory.path)
        let connector = makeConnector(store: store, launcher: launcher, tools: tools, registry: registry)

        _ = try await connector.start(projectPath: projectDirectory.path, prompt: "第一轮")
        let first = launcher.last?.request.environment[AgentToolsInjection.taskTokenVariable]
        launcher.last?.exit(0)
        await assertEventually { await store.owner(of: "pi:s1") == .observer }

        try fixture.write(id: "s1", lines: [PiFixture.header(id: "s1", cwd: projectDirectory.path)], modifiedAt: Date())
        _ = try await connector.followUp(taskId: "pi:s1", prompt: "第二轮")
        XCTAssertEqual(launcher.processes.current.count, 2)
        XCTAssertEqual(launcher.last?.request.environment[AgentToolsInjection.taskTokenVariable], first)
    }

    func testFollowUpRefusedWhileOwnRunIsActive() async throws {
        let store = makeStore()
        let launcher = FakePiLauncher.emittingHeader(id: "s1")
        let connector = makeConnector(store: store, launcher: launcher)
        _ = try await connector.start(projectPath: projectDirectory.path, prompt: "长任务")
        do {
            _ = try await connector.followUp(taskId: "pi:s1", prompt: "插一句")
            XCTFail("正在跑的会话不能续聊")
        } catch {
            XCTAssertEqual((error as? ConnectorError)?.message, "这个会话正在运行，等它这一轮结束再续聊")
        }
        XCTAssertEqual(launcher.processes.current.count, 1)
    }

    /// 电脑上正开着的会话不是我们的进程：再起一个 `--session` 会和它抢着写同一份 JSONL。
    func testFollowUpRefusedWhileDesktopSessionIsRunning() async throws {
        try fixture.write(id: "desk", lines: [PiFixture.header(id: "desk", cwd: projectDirectory.path)], modifiedAt: Date())
        let store = makeStore()
        await store.upsert(TaskRecord(id: "pi:desk", agentId: "agent-1", source: .pi, title: "桌面",
                                      projectPath: projectDirectory.path, projectName: "project", status: .running,
                                      origin: .desktop, controllable: false,
                                      startedAt: "2026-09-20T01:00:00Z", updatedAt: "2026-09-20T01:00:02Z"))
        let launcher = FakePiLauncher.emittingHeader(id: "desk", cwd: projectDirectory.path)
        let connector = makeConnector(store: store, launcher: launcher)
        do {
            _ = try await connector.followUp(taskId: "pi:desk", prompt: "插一句")
            XCTFail("电脑上正在跑的会话不能续聊")
        } catch {
            XCTAssertEqual((error as? ConnectorError)?.message, "这个会话正在电脑上运行，等它停下再续聊")
        }
        XCTAssertEqual(launcher.processes.current.count, 0)
    }

    /// 手机和手表同时发续聊：header 到之前 `active` 还是空的，第二条必须被挡住，而不是再起一个 pi。
    func testConcurrentFollowUpsLaunchOnlyOnce() async throws {
        try fixture.write(id: "s2", lines: [PiFixture.header(id: "s2", cwd: projectDirectory.path)],
                          modifiedAt: Date().addingTimeInterval(-600))
        let store = makeStore()
        // header 不立刻吐：第一条续聊停在等 header 的地方。
        let launcher = FakePiLauncher()
        let connector = makeConnector(store: store, launcher: launcher)
        let first = Task { try await connector.followUp(taskId: "pi:s2", prompt: "一") }
        await assertEventually { launcher.processes.current.count == 1 }
        do {
            _ = try await connector.followUp(taskId: "pi:s2", prompt: "二")
            XCTFail("同一会话的第二条续聊必须被挡住")
        } catch {
            XCTAssertEqual((error as? ConnectorError)?.message, "这个会话正在运行，等它这一轮结束再续聊")
        }
        XCTAssertEqual(launcher.processes.current.count, 1)
        launcher.last?.emit(PiFixture.header(id: "s2", cwd: projectDirectory.path))
        _ = try await first.value
        launcher.last?.exit(0)
    }

    func testFollowUpWithoutSessionFileThrows() async {
        let connector = makeConnector(store: makeStore(), launcher: FakePiLauncher())
        do {
            _ = try await connector.followUp(taskId: "pi:missing", prompt: "hi")
            XCTFail("没有记录文件应当报错")
        } catch {
            XCTAssertEqual((error as? ConnectorError)?.message, "找不到这个 Pi 会话的记录文件")
        }
    }

    // MARK: - stop

    func testStopTerminatesOwnProcessesAndMarksInterrupted() async throws {
        let store = makeStore()
        let launcher = FakePiLauncher.emittingHeader(id: "s1")
        let connector = makeConnector(store: store, launcher: launcher)
        _ = try await connector.start(projectPath: projectDirectory.path, prompt: "长任务")
        let process = try XCTUnwrap(launcher.last)

        await connector.stop()
        XCTAssertEqual(process.terminations.current, 1)
        process.exit(15)
        await assertEventually { await store.owner(of: "pi:s1") == .observer }
        let task = await store.task(id: "pi:s1")
        XCTAssertEqual(task?.status, .interrupted, "停机杀掉的不算失败")
    }
}

/// `XCTUnwrap` 的 autoclosure 不支持 await。
private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
