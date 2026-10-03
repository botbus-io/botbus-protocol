import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 假的 `hermes` 子进程：记下每次启动的请求，测试手动往 stdout 喂行、让它退出。
final class FakeHermesProcess: HermesRunningProcess, @unchecked Sendable {
    let interrupts = Locked(0)
    let terminations = Locked(0)
    func interrupt() { interrupts.withLock { $0 += 1 } }
    func terminate() { terminations.withLock { $0 += 1 } }
}

final class FakeHermesLauncher: HermesProcessLauncher, @unchecked Sendable {
    struct Launch: @unchecked Sendable {
        let request: HermesLaunchRequest
        let output: @Sendable (Data) -> Void
        let exit: @Sendable (Int32) -> Void
        let process: FakeHermesProcess

        func emit(_ objects: [String: Any]...) {
            for object in objects {
                var data = try! JSONSerialization.data(withJSONObject: object)
                data.append(UInt8(ascii: "\n"))
                output(data)
            }
        }
    }

    let launches = Locked<[Launch]>([])
    /// 在 `launch` 里同步调用：用来模拟"一起来就吐完、立刻退出"的极快一轮。
    let onLaunch: (@Sendable (Launch) -> Void)?

    init(onLaunch: (@Sendable (Launch) -> Void)? = nil) { self.onLaunch = onLaunch }

    func launch(_ request: HermesLaunchRequest, output: @escaping @Sendable (Data) -> Void,
                exit: @escaping @Sendable (Int32) -> Void) throws -> any HermesRunningProcess {
        let launch = Launch(request: request, output: output, exit: exit, process: FakeHermesProcess())
        launches.withLock { $0.append(launch) }
        onLaunch?(launch)
        return launch.process
    }

    func waitForLaunch(_ count: Int) async -> Launch? {
        _ = await eventually { self.launches.current.count >= count }
        let all = launches.current
        return all.count >= count ? all[count - 1] : nil
    }
}

final class HermesConnectorTests: XCTestCase {
    private var project: URL!
    private var home: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-conn-\(UUID().uuidString)")
        project = root.appendingPathComponent("shop", isDirectory: true)
        home = root.appendingPathComponent("hermes-home", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private func makeStore() -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                  connectors: ConnectorRegistry(descriptors: [
                      ConnectorDescriptor(kind: .hermes, displayName: "Hermes", defaultEnabled: true) {
                          ConnectorProbe(available: true, status: .ok)
                      },
                  ]))
    }

    private func makeConnector(store: TaskStore, launcher: FakeHermesLauncher,
                               binary: String? = "/opt/fake/bin/hermes",
                               tools: AgentToolsConfiguration? = nil,
                               registry: TaskContextRegistry = TaskContextRegistry(),
                               finished: Locked<Int> = Locked(0)) -> HermesConnector {
        let paths = HermesPaths(hermesHome: home)
        return HermesConnector(store: store, paths: { paths }, binary: { binary }, launcher: launcher,
                               tools: { tools }, registry: registry,
                               onRunFinished: { finished.withLock { $0 += 1 } })
    }

    /// 起一轮：后台调 `start`，等假进程被拉起后吐 init，拿到回执。
    private func startRun(_ connector: HermesConnector, _ launcher: FakeHermesLauncher, session: String = "sess-1",
                          prompt: String = "把结账按钮修好", index: Int = 1)
        async throws -> (ConnectorOutcome, FakeHermesLauncher.Launch) {
        let path = project.path
        let pending = Task { try await connector.start(projectPath: path, prompt: prompt) }
        let launch = try await XCTUnwrapAsync(await launcher.waitForLaunch(index))
        launch.emit(["type": "system", "subtype": "init", "session_id": session])
        return (try await pending.value, launch)
    }

    private func requireTask(_ store: TaskStore, _ id: String,
                             file: StaticString = #filePath, line: UInt = #line) async throws -> TaskRecord {
        let record = await store.task(id: id)
        return try XCTUnwrap(record, file: file, line: line)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    // MARK: - 参数

    func testArguments() {
        XCTAssertEqual(HermesConnector.arguments(prompt: "-v 看看", projectPath: "/p", resuming: nil),
                       ["chat", "-q", "-v 看看", "--format", "stream-json", "--in", "/p"])
        XCTAssertEqual(HermesConnector.arguments(prompt: "继续", projectPath: "/p", resuming: "s1"),
                       ["chat", "-q", "继续", "--format", "stream-json", "--in", "/p", "--resume", "s1"])
    }

    // MARK: - 一轮的生命周期

    func testStartClaimsLiveThenFinishReleasesAndPokesObserver() async throws {
        let store = makeStore()
        let launcher = FakeHermesLauncher()
        let finished = Locked(0)
        let connector = makeConnector(store: store, launcher: launcher, finished: finished)

        let (outcome, launch) = try await startRun(connector, launcher)
        XCTAssertEqual(outcome, ConnectorOutcome(taskId: "sess-1", retainsLiveOwnership: true))
        XCTAssertEqual(launch.request.executable, "/opt/fake/bin/hermes")
        XCTAssertEqual(launch.request.arguments, ["chat", "-q", "把结账按钮修好", "--format", "stream-json", "--in", project.path])
        XCTAssertEqual(launch.request.workingDirectory, project.path)
        XCTAssertEqual(PlatformPath.splitSearchPath(PlatformPath.searchPath(in: launch.request.environment) ?? "").first,
                       "/opt/fake/bin", "可执行文件目录补到 PATH 最前")
        XCTAssertNil(launch.request.environment[AgentToolsInjection.taskTokenVariable], "没配工具就不注入")
        XCTAssertNil(launch.request.environment[HermesConnector.ephemeralPromptVariable])

        var record = try await requireTask(store, "hermes:sess-1")
        XCTAssertEqual(record.status, .running)
        XCTAssertEqual(record.origin, .watch)
        XCTAssertEqual(record.title, "把结账按钮修好")
        XCTAssertEqual(record.projectPath, PlatformPath.canonical(project.path))
        XCTAssertEqual(record.projectName, "shop")
        XCTAssertTrue(record.controllable)
        let ownerWhileRunning = await store.owner(of: "hermes:sess-1")
        XCTAssertEqual(ownerWhileRunning, .live, "自己起的一轮里观察者不许改写")

        launch.emit(["type": "text", "text": "我先看看"],
                    ["type": "tool_use", "name": "terminal"],
                    ["type": "tool_result"],
                    ["type": "text", "text": "修好了，"],
                    ["type": "text", "text": "按钮居中了"])
        launch.emit(["type": "result", "session_id": "sess-1", "exit_code": 0])
        launch.exit(0)

        await assertEventually { finished.current == 1 }
        record = try await requireTask(store, "hermes:sess-1")
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.lastMessage, "修好了，按钮居中了", "只留最后一次工具调用之后的增量")
        let ownerAfter = await store.owner(of: "hermes:sess-1")
        XCTAssertEqual(ownerAfter, .observer, "跑完交还给观察者")
    }

    func testResultErrorMarksFailed() async throws {
        let store = makeStore()
        let launcher = FakeHermesLauncher()
        let finished = Locked(0)
        let connector = makeConnector(store: store, launcher: launcher, finished: finished)
        let (_, launch) = try await startRun(connector, launcher)

        launch.emit(["type": "result", "session_id": "sess-1", "exit_code": 1, "error": "API key 无效"])
        launch.exit(1)
        await assertEventually { finished.current == 1 }
        let record = try await requireTask(store, "hermes:sess-1")
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.lastMessage, "API key 无效", "没有回答时把错误写进最后消息")
    }

    func testExitWithoutResultIsFailedEvenWithZeroStatus() async throws {
        let store = makeStore()
        let launcher = FakeHermesLauncher()
        let finished = Locked(0)
        let connector = makeConnector(store: store, launcher: launcher, finished: finished)
        let (_, launch) = try await startRun(connector, launcher)

        launch.emit(["type": "text", "text": "写到一半"])
        launch.exit(0)
        await assertEventually { finished.current == 1 }
        let record = try await requireTask(store, "hermes:sess-1")
        XCTAssertEqual(record.status, .failed, "正常结束一定有 result 行")
        XCTAssertEqual(record.lastMessage, "写到一半")
    }

    func testExitBeforeInitFailsStart() async throws {
        let store = makeStore()
        let launcher = FakeHermesLauncher(onLaunch: { launch in
            launch.output(Data("hermes: config error\n".utf8))
            launch.exit(2)
        })
        let connector = makeConnector(store: store, launcher: launcher)
        do {
            _ = try await connector.start(projectPath: project.path, prompt: "hi")
            XCTFail("没拿到 session id 必须报错")
        } catch let error as ConnectorError {
            XCTAssertTrue(error.message.hasPrefix("hermes 退出了，没有拿到 session id"))
        }
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    /// init、result、退出在 `start` 登记这一轮之前就全到了：收尾不能丢。
    func testRunFinishingBeforeRegistrationStillCompletes() async throws {
        let store = makeStore()
        let launcher = FakeHermesLauncher(onLaunch: { launch in
            launch.emit(["type": "system", "subtype": "init", "session_id": "quick"],
                        ["type": "result", "session_id": "quick", "exit_code": 0, "text": "一句话答完"])
            launch.exit(0)
        })
        let finished = Locked(0)
        let connector = makeConnector(store: store, launcher: launcher, finished: finished)
        let outcome = try await connector.start(projectPath: project.path, prompt: "快问")
        XCTAssertEqual(outcome.taskId, "quick")
        // 照分发器的做法收尾：回执之后 claim 一次，不保留就立刻 release。收尾可能落在登记之前
        // （回执不保留所有权）或之后（回执保留、连接器 release 在分发器 claim 之前）——后一种靠延迟补放兜底。
        await store.claimLive("hermes:quick")
        if !outcome.retainsLiveOwnership { await store.releaseLive("hermes:quick") }

        await assertEventually { finished.current == 1 }
        let record = try await requireTask(store, "hermes:quick")
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.lastMessage, "一句话答完")
        let deadline = Date().addingTimeInterval(3)
        var owner = await store.owner(of: "hermes:quick")
        while owner != .observer, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            owner = await store.owner(of: "hermes:quick")
        }
        XCTAssertEqual(owner, .observer, "所有权必须最终交还给观察者")
    }

    func testStartValidatesBinaryAndDirectory() async {
        let store = makeStore()
        let launcher = FakeHermesLauncher()
        do {
            _ = try await makeConnector(store: store, launcher: launcher, binary: nil).start(projectPath: project.path, prompt: "x")
            XCTFail("没有 hermes 要报错")
        } catch let error as ConnectorError {
            // 旧手机不认诊断，看的是原话。
            XCTAssertEqual(error.message, "本机没找到 hermes 可执行文件")
            XCTAssertEqual(error.diagnosis, .agentNotInstalled)
        } catch { XCTFail("\(error)") }
        do {
            _ = try await makeConnector(store: store, launcher: launcher).start(projectPath: "/nonexistent/dir", prompt: "x")
            XCTFail("目录不存在要报错")
        } catch let error as ConnectorError {
            XCTAssertEqual(error.message, "项目目录不存在：/nonexistent/dir")
            XCTAssertEqual(error.diagnosis, .projectMissing)
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(launcher.launches.current.isEmpty)
    }

    // MARK: - 中断

    func testInterruptOwnProcessKeepsInterruptedStatus() async throws {
        let store = makeStore()
        let launcher = FakeHermesLauncher()
        let finished = Locked(0)
        let connector = makeConnector(store: store, launcher: launcher, finished: finished)
        let (_, launch) = try await startRun(connector, launcher)

        let outcome = try await connector.interrupt(taskId: "hermes:sess-1")
        XCTAssertEqual(outcome, ConnectorOutcome(taskId: "sess-1", retainsLiveOwnership: true))
        XCTAssertEqual(launch.process.interrupts.current, 1)
        var record = try await requireTask(store, "hermes:sess-1")
        XCTAssertEqual(record.status, .interrupted)

        launch.exit(130)
        await assertEventually { finished.current == 1 }
        record = try await requireTask(store, "hermes:sess-1")
        XCTAssertEqual(record.status, .interrupted, "进程退出不把中断改回 failed / completed")
        let owner = await store.owner(of: "hermes:sess-1")
        XCTAssertEqual(owner, .observer)
    }

    func testInterruptDesktopSessionIsRefused() async {
        let connector = makeConnector(store: makeStore(), launcher: FakeHermesLauncher())
        do {
            _ = try await connector.interrupt(taskId: "hermes:desk")
            XCTFail("不是我们的进程")
        } catch let error as ConnectorError {
            XCTAssertEqual(error.message, "这个会话是在电脑上启动的，只能在电脑上中断")
        } catch { XCTFail("\(error)") }
    }

    func testApproveIsUnsupported() async {
        let connector = makeConnector(store: makeStore(), launcher: FakeHermesLauncher())
        do {
            _ = try await connector.approve(taskId: "hermes:s", requestId: "r", decision: .allow)
            XCTFail("-q 模式没有审批通道")
        } catch let error as ConnectorError {
            XCTAssertTrue(error.message.hasPrefix("Hermes 的 -q 模式没有审批通道"))
        } catch { XCTFail("\(error)") }
    }

    func testImagesAreRefusedWithoutLaunching() async throws {
        let store = makeStore()
        let launcher = FakeHermesLauncher()
        let connector = makeConnector(store: store, launcher: launcher)
        let image = [URL(fileURLWithPath: "/tmp/a.jpg")]
        for attempt in [
            { try await connector.start(projectPath: "/tmp", prompt: "看图", images: image) },
            { try await connector.followUp(taskId: "hermes:s", prompt: "看图", images: image) },
        ] as [@Sendable () async throws -> ConnectorOutcome] {
            do {
                _ = try await attempt()
                XCTFail("Hermes 不支持发图")
            } catch {
                XCTAssertEqual((error as? ConnectorError)?.message, "这个 Agent 暂不支持发图")
            }
        }
        XCTAssertTrue(launcher.launches.current.isEmpty)
    }

    func testStopTerminatesOwnProcesses() async throws {
        let launcher = FakeHermesLauncher()
        let connector = makeConnector(store: makeStore(), launcher: launcher)
        let (_, launch) = try await startRun(connector, launcher)
        await connector.stop()
        XCTAssertEqual(launch.process.terminations.current, 1)
    }

    // MARK: - 续聊

    private func makeStateDB(sessions: [(id: String, cwd: String?)]) throws {
        let db = try SQLiteDatabase(path: home.appendingPathComponent("state.db").path, readOnly: false)
        try db.execute(HermesStateReaderTests.currentSchema)
        for session in sessions {
            let cwd = session.cwd.map { "'\($0)'" } ?? "NULL"
            try db.execute("INSERT INTO sessions (id, cwd, started_at) VALUES ('\(session.id)', \(cwd), 1789700000)")
        }
    }

    func testFollowUpResumesInSessionCwdFromStateDB() async throws {
        try makeStateDB(sessions: [("desk", project.path)])
        let store = makeStore()
        let launcher = FakeHermesLauncher()
        let finished = Locked(0)
        let connector = makeConnector(store: store, launcher: launcher, finished: finished)

        let pending = Task { try await connector.followUp(taskId: "hermes:desk", prompt: "再加个测试") }
        let launch = try await XCTUnwrapAsync(await launcher.waitForLaunch(1))
        XCTAssertEqual(launch.request.arguments,
                       ["chat", "-q", "再加个测试", "--format", "stream-json", "--in", project.path, "--resume", "desk"])
        XCTAssertEqual(launch.request.workingDirectory, project.path)
        launch.emit(["type": "system", "subtype": "init", "session_id": "desk"])
        let outcome = try await pending.value
        XCTAssertEqual(outcome, ConnectorOutcome(taskId: "desk", retainsLiveOwnership: true))
        let record = try await requireTask(store, "hermes:desk")
        XCTAssertEqual(record.status, .running)

        // 这一轮还在跑：同一会话再续聊要被挡住。
        do {
            _ = try await connector.followUp(taskId: "hermes:desk", prompt: "又一句")
            XCTFail("正在跑的会话不能并发续聊")
        } catch let error as ConnectorError {
            XCTAssertEqual(error.message, "这个会话还在跑，等这一轮结束再续聊")
        }
        XCTAssertEqual(launcher.launches.current.count, 1)

        launch.emit(["type": "result", "session_id": "desk", "exit_code": 0, "text": "加好了"])
        launch.exit(0)
        await assertEventually { finished.current == 1 }
        let done = try await requireTask(store, "hermes:desk")
        XCTAssertEqual(done.status, .completed)
        XCTAssertEqual(done.lastMessage, "加好了")
    }

    func testFollowUpThatBranchesReturnsNewSessionID() async throws {
        try makeStateDB(sessions: [("desk", project.path)])
        let store = makeStore()
        let launcher = FakeHermesLauncher()
        let connector = makeConnector(store: store, launcher: launcher)

        let pending = Task { try await connector.followUp(taskId: "hermes:desk", prompt: "分支一下") }
        let launch = try await XCTUnwrapAsync(await launcher.waitForLaunch(1))
        launch.emit(["type": "system", "subtype": "init", "session_id": "desk-2"])
        let outcome = try await pending.value
        XCTAssertEqual(outcome.taskId, "desk-2", "回执必须是实际的 session id")
        let branched = try await requireTask(store, "hermes:desk-2")
        XCTAssertEqual(branched.origin, .watch)
        XCTAssertEqual(branched.title, "分支一下")
        let owner = await store.owner(of: "hermes:desk-2")
        XCTAssertEqual(owner, .live)
    }

    func testFollowUpFallsBackToOwnSessionMemory() async throws {
        let store = makeStore()
        let launcher = FakeHermesLauncher()
        let finished = Locked(0)
        let connector = makeConnector(store: store, launcher: launcher, finished: finished)
        let (_, first) = try await startRun(connector, launcher, session: "mine")
        first.emit(["type": "result", "session_id": "mine", "exit_code": 0, "text": "第一轮"])
        first.exit(0)
        await assertEventually { finished.current == 1 }

        // state.db 不存在（Hermes 还没落盘）：用自己记得的目录。
        let pending = Task { try await connector.followUp(taskId: "hermes:mine", prompt: "第二轮") }
        let second = try await XCTUnwrapAsync(await launcher.waitForLaunch(2))
        XCTAssertEqual(second.request.workingDirectory, project.path)
        XCTAssertEqual(Array(second.request.arguments.suffix(2)), ["--resume", "mine"])
        second.emit(["type": "system", "subtype": "init", "session_id": "mine"])
        _ = try await pending.value
        let record = try await requireTask(store, "hermes:mine")
        XCTAssertEqual(record.title, "把结账按钮修好", "同一会话续聊沿用原标题")
        XCTAssertEqual(record.status, .running)
    }

    func testFollowUpWithoutKnownDirectoryFails() async throws {
        try makeStateDB(sessions: [("chat", nil)])
        let connector = makeConnector(store: makeStore(), launcher: FakeHermesLauncher())
        do {
            _ = try await connector.followUp(taskId: "hermes:chat", prompt: "x")
            XCTFail("没有目录不能续聊")
        } catch let error as ConnectorError {
            XCTAssertEqual(error.message, "找不到这个 Hermes 会话的项目目录")
        }
    }

    func testFollowUpRefusesDesktopRunningSession() async throws {
        try makeStateDB(sessions: [("busy", project.path)])
        let store = makeStore()
        await store.upsert(TaskRecord(id: "hermes:busy", agentId: "agent-1", source: .hermes, title: "t",
                                      projectPath: project.path, projectName: "shop", status: .running,
                                      origin: .desktop, controllable: false,
                                      startedAt: "2026-09-18T00:00:00Z", updatedAt: "2026-09-18T00:00:00Z"))
        let launcher = FakeHermesLauncher()
        let connector = makeConnector(store: store, launcher: launcher)
        do {
            _ = try await connector.followUp(taskId: "hermes:busy", prompt: "x")
            XCTFail("桌面上正在跑的会话不能抢")
        } catch let error as ConnectorError {
            XCTAssertEqual(error.message, "这个会话正在电脑上运行，等它停下再续聊")
        }
        XCTAssertTrue(launcher.launches.current.isEmpty)
    }

    // MARK: - agent 工具注入

    func testInjectsToolEnvironmentAndBindsToken() async throws {
        let cli = project.appendingPathComponent(fakeCLIName)
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let configuration = AgentToolsConfiguration(cliPath: cli.path, toolsURL: "http://127.0.0.1:4567")
        let registry = TaskContextRegistry(generateToken: { "tok-hermes" })
        let launcher = FakeHermesLauncher()
        let connector = makeConnector(store: makeStore(), launcher: launcher, tools: configuration, registry: registry)

        let (_, launch) = try await startRun(connector, launcher)
        let environment = launch.request.environment
        XCTAssertEqual(environment[AgentToolsInjection.toolsURLVariable], "http://127.0.0.1:4567")
        XCTAssertEqual(environment[AgentToolsInjection.taskTokenVariable], "tok-hermes")
        XCTAssertEqual(environment[AgentToolsInjection.cliVariable], cli.path)
        let prompt = try XCTUnwrap(environment[HermesConnector.ephemeralPromptVariable])
        XCTAssertTrue(prompt.contains("by running the `botbus` CLI at `\(cli.path)`"), "只讲 CLI 的那版说明")
        XCTAssertFalse(prompt.contains("MCP server"))
        XCTAssertFalse(launch.request.arguments.contains { $0.contains("botbus") }, "-q 模式不加任何 MCP 参数")
        let bound = await registry.taskId(for: "tok-hermes")
        XCTAssertEqual(bound, "hermes:sess-1")
    }

    // MARK: - 真的 Process（假的 hermes 脚本）

    private func script(_ body: String) throws -> String {
        try skipPOSIXScriptOnWindows()
        let url = project.deletingLastPathComponent().appendingPathComponent("fake-hermes")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// 走 `HermesSubprocessLauncher`：参数、工作目录、stdout 分行、退出后收尾都是真的。
    func testSubprocessLauncherRunsScriptToCompletion() async throws {
        let executable = try script("""
            echo '{"type":"system","subtype":"init","session_id":"real-1"}'
            printf '{"type":"text","text":"%s|%s"}\\n' "$(pwd)" "$3"
            printf '{"type":"result","session_id":"real-1","exit_code":0}'
            """)
        let store = makeStore()
        let finished = Locked(0)
        let paths = HermesPaths(hermesHome: home)
        let connector = HermesConnector(store: store, paths: { paths }, binary: { executable },
                                        onRunFinished: { finished.withLock { $0 += 1 } })
        let outcome = try await connector.start(projectPath: project.path, prompt: "脚本")
        XCTAssertEqual(outcome.taskId, "real-1")
        await assertEventually(timeout: 5) { finished.current == 1 }
        let record = try await requireTask(store, "hermes:real-1")
        XCTAssertEqual(record.status, .completed)
        // 临时目录在 /var 与 /private/var 之间有软链接，只比结尾。
        let message = try XCTUnwrap(record.lastMessage)
        XCTAssertTrue(message.hasSuffix("/\(project.deletingLastPathComponent().lastPathComponent)/shop|脚本"),
                      "工作目录是项目目录；prompt 是 -q 的值：\(message)")
    }

    /// 脚本退出了，但它起的后台进程还攥着 stdout：EOF 不来也要在排空超时后收尾。
    func testSubprocessLauncherDoesNotWaitForeverForEOF() async throws {
        let executable = try script("""
            echo '{"type":"system","subtype":"init","session_id":"real-2"}'
            echo '{"type":"result","exit_code":0,"text":"ok"}'
            sleep 5 &
            exit 0
            """)
        let store = makeStore()
        let finished = Locked(0)
        let paths = HermesPaths(hermesHome: home)
        let connector = HermesConnector(store: store, paths: { paths }, binary: { executable },
                                        onRunFinished: { finished.withLock { $0 += 1 } })
        _ = try await connector.start(projectPath: project.path, prompt: "x")
        await assertEventually(timeout: 6) { finished.current == 1 }
        let record = try await requireTask(store, "hermes:real-2")
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.lastMessage, "ok")
    }

    // MARK: - stream-json 解析

    func testStreamReaderHandlesSplitChunksAndGarbage() {
        var reader = HermesStreamReader()
        XCTAssertNil(reader.consume(Data("not json\n{\"type\":\"sys".utf8)))
        XCTAssertEqual(reader.consume(Data("tem\",\"subtype\":\"init\",\"session_id\":\"abc\"}\n".utf8)), "abc")
        XCTAssertNil(reader.consume(Data("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"other\"}\n".utf8)),
                     "只认第一个 session id")
        _ = reader.consume(Data("{\"type\":\"text\",\"text\":\"半截\"}\n{\"type\":\"result\",\"exit_code\":0,\"text\":\"最终\"}".utf8))
        let result = reader.finish(exitStatus: 0)
        XCTAssertEqual(result, HermesStreamReader.Result(sessionID: "abc", lastText: "最终", failed: false, errorMessage: nil),
                       "没有换行结尾的最后一行也要处理；result 自带的文本优先")
        XCTAssertNil(reader.consume(Data("{\"type\":\"system\",\"session_id\":\"late\"}\n".utf8)), "结束之后的数据忽略")
    }

    func testStreamReaderFailureSignals() {
        var nonzero = HermesStreamReader()
        _ = nonzero.consume(Data("{\"type\":\"result\",\"exit_code\":0}\n".utf8))
        XCTAssertEqual(nonzero.finish(exitStatus: 1).failed, true, "进程退出码非 0 也算失败")

        var errorObject = HermesStreamReader()
        _ = errorObject.consume(Data("{\"type\":\"result\",\"exit_code\":0,\"error\":{\"message\":\"限流\"}}\n".utf8))
        let failed = errorObject.finish(exitStatus: 0)
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.errorMessage, "限流")

        var nullError = HermesStreamReader()
        _ = nullError.consume(Data("{\"type\":\"result\",\"exit_code\":0,\"error\":null,\"text\":\"好\"}\n".utf8))
        XCTAssertFalse(nullError.finish(exitStatus: 0).failed, "error: null 不算错")
    }
}
