import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

// MARK: - 假的 codex exec

/// 假的 `codex exec` 子进程：测试往 stdout 投事件行；`interrupt` / `terminate` 模拟进程退出（stdout 关掉）。
/// 不起任何真实进程、不碰 `~/.codex`。
final class FakeCodexExecProcess: CodexExecProcess, @unchecked Sendable {
    let stdin = Locked(Data())
    let inputClosed = Locked(false)
    let interrupted = Locked(false)
    let terminated = Locked(false)
    let exit: CodexProcessExit

    private var iterator: AsyncStream<Data>.Iterator
    private let continuation: AsyncStream<Data>.Continuation

    init(exit: CodexProcessExit = CodexProcessExit(status: 0)) {
        self.exit = exit
        var captured: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        iterator = stream.makeAsyncIterator()
    }

    func readStdout() async throws -> Data? { await iterator.next() }
    func writeStdin(_ data: Data) async throws { stdin.withLock { $0.append(data) } }
    func closeInput() { inputClosed.withLock { $0 = true } }
    func interrupt() {
        interrupted.withLock { $0 = true }
        continuation.finish()
    }
    func terminate() {
        terminated.withLock { $0 = true }
        continuation.finish()
    }
    func waitForExit() async -> CodexProcessExit { exit }

    /// 原样投一段字节（可以是半行）。
    func deliverRaw(_ text: String) { continuation.yield(Data(text.utf8)) }
    func deliver(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        continuation.yield(data + Data("\n".utf8))
    }
    func finish() { continuation.finish() }

    var prompt: String { String(decoding: stdin.current, as: UTF8.self) }
}

final class FakeCodexExecLauncher: CodexExecLauncher, @unchecked Sendable {
    struct Launch {
        let arguments: [String]
        let workingDirectory: String
        let process: FakeCodexExecProcess
    }

    private let state = Locked<[Launch]>([])
    /// 每次起进程后立刻投给它的事件（默认：线程起来、这一轮开始）。
    let script: Locked<[[String: Any]]>
    /// 投完 `script` 就让进程退出（stdout 关掉）。
    let exitsAfterScript = Locked(false)

    init(threadId: String = "exec-1") {
        script = Locked([["type": "thread.started", "thread_id": threadId], ["type": "turn.started"]])
    }

    var launches: [Launch] { state.current }
    var latest: Launch? { state.current.last }

    func launch(arguments: [String], workingDirectory: String) throws -> any CodexExecProcess {
        let process = FakeCodexExecProcess()
        for event in script.current { process.deliver(event) }
        if exitsAfterScript.current { process.finish() }
        state.withLock { $0.append(Launch(arguments: arguments, workingDirectory: workingDirectory, process: process)) }
        return process
    }
}

// MARK: - 测试

final class CodexExecTests: XCTestCase {
    private static let agentId = "agent-mac-000000001"

    private struct Rig {
        let launcher: FakeCodexLauncher
        /// 必须留着：`FakeSleeper.sleep` 弱引用它，释放了的话假 app-server 的每次超时都立刻到点。
        let sleeper: FakeSleeper
        let exec: FakeCodexExecLauncher
        let store: TaskStore
        let registry: TaskContextRegistry
        let connector: CodexConnector
        let process: FakeCodexProcess
        let responder: CodexAutoResponder
    }

    private func makeRig(exec: FakeCodexExecLauncher = FakeCodexExecLauncher(),
                         tools: AgentToolsConfiguration? = AgentToolsConfiguration(cliPath: anyExecutablePath,
                                                                                   toolsURL: "http://127.0.0.1:9")) async -> Rig {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = CodexAppServer(launcher: launcher,
                                    configuration: CodexAppServer.Configuration(clientName: "BotBusTest",
                                                                                clientVersion: "0.0.0"),
                                    sleeper: sleeper.sleep)
        let store = TaskStore(identity: AgentIdentity(agentId: Self.agentId, name: "本机", appVersion: "1.0"))
        let registry = TaskContextRegistry()
        let connector = CodexConnector(server: server, store: store, tools: { tools }, registry: registry,
                                       streamInterval: 0.05, execLauncher: { exec })
        await connector.start()
        var found: FakeCodexProcess?
        await assertEventually {
            guard let latest = launcher.latest else { return false }
            found = latest
            return latest.requests(method: "initialized").count == 1
        }
        let process = found ?? FakeCodexProcess()
        let responder = CodexAutoResponder(process)
        responder.installDefaults()
        responder.start()
        return Rig(launcher: launcher, sleeper: sleeper, exec: exec, store: store, registry: registry, connector: connector,
                   process: process, responder: responder)
    }

    private func teardown(_ rig: Rig) async {
        rig.responder.stop()
        await rig.connector.stop()
    }

    private func task(_ rig: Rig, _ id: String = "codex:exec-1") async -> TaskRecord? {
        await rig.store.task(id: id)
    }

    /// `XCTUnwrap` 的参数是 autoclosure，塞不进 await：先把记录取回来再解包。
    private func requireTask(_ rig: Rig, _ id: String = "codex:exec-1",
                             file: StaticString = #filePath, line: UInt = #line) async throws -> TaskRecord {
        let record = await task(rig, id)
        return try XCTUnwrap(record, "本机没有任务 \(id)", file: file, line: line)
    }

    /// 团队派活的那种调用：带预签 token、换掉的说明文字、员工 id，无人值守。
    private func startUnattended(_ rig: Rig, prompt: String = "【小明 · 开发】修登录页的 bug\n看板任务 #3",
                                 selection: ModelSelection = ModelSelection()) async throws -> ConnectorOutcome {
        let token = await rig.registry.issue()
        let context = AgentRunContext(token: token, instructions: "你是团队的开发。\n用 \"botbus team\" 改看板。",
                                      unattended: true, environment: ["BOTBUS_TEAM_MEMBER": "dev"])
        return try await AgentRunContext.$current.withValue(context) {
            try await rig.connector.start(projectPath: "/tmp/project", prompt: prompt, images: [], selection: selection)
        }
    }

    func testUnattendedStartRunsCodexExecInsteadOfAppServer() async throws {
        let rig = await makeRig()
        let outcome = try await startUnattended(rig, selection: ModelSelection(model: "gpt-5.5", effort: "high"))
        XCTAssertEqual(outcome.taskId, "codex:exec-1")
        XCTAssertTrue(outcome.retainsLiveOwnership)

        // 没碰 app-server：桌面桥接时那是桌面的 app-server，线程会出现在桌面里。
        XCTAssertTrue(rig.process.requests(method: "thread/start").isEmpty)
        XCTAssertTrue(rig.process.requests(method: "turn/start").isEmpty)

        let launch = try XCTUnwrap(rig.exec.latest)
        XCTAssertEqual(launch.workingDirectory, "/tmp/project")
        let arguments = launch.arguments
        XCTAssertEqual(Array(arguments.prefix(5)), ["exec", "--json", "--skip-git-repo-check", "-C", "/tmp/project"])
        XCTAssertTrue(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertEqual(arguments.last, "-", "提示词走 stdin")
        XCTAssertTrue(arguments.contains("-m"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-m")! + 1], "gpt-5.5")
        let overrides = zip(arguments, arguments.dropFirst()).filter { $0.0 == "-c" }.map(\.1)
        XCTAssertTrue(overrides.contains(#"model_reasoning_effort="high""#))
        XCTAssertTrue(overrides.contains(#"developer_instructions="你是团队的开发。\n用 \"botbus team\" 改看板。""#))
        // cliPath 要真实存在且可执行，注入才生效（Windows 上是 cmd.exe，反斜杠在 TOML 里转义，与 JSON 相同）。
        XCTAssertTrue(overrides.contains("mcp_servers.botbus.command=\"\(anyExecutableJSON)\""))
        XCTAssertTrue(overrides.contains(#"mcp_servers.botbus.args=["mcp"]"#))
        XCTAssertTrue(overrides.contains(#"shell_environment_policy.set.BOTBUS_TEAM_MEMBER="dev""#))
        XCTAssertTrue(overrides.contains(#"mcp_servers.botbus.env.BOTBUS_TOOLS_URL="http://127.0.0.1:9""#))

        XCTAssertEqual(launch.process.prompt, "【小明 · 开发】修登录页的 bug\n看板任务 #3")
        XCTAssertTrue(launch.process.inputClosed.current)

        // 登记成本连接器实时驱动的任务：手机上看得到、能停。
        let task = try await requireTask(rig)
        XCTAssertEqual(task.status, .running)
        XCTAssertEqual(task.origin, .watch)
        XCTAssertEqual(task.title, "【小明 · 开发】修登录页的 bug 看板任务 #3")
        XCTAssertEqual(task.workingDirectory, "/tmp/project")
        XCTAssertEqual(task.model, "gpt-5.5")
        XCTAssertTrue(task.controllable)
        let live = await rig.connector.liveThreadIds()
        XCTAssertEqual(live, ["exec-1"])
        // 预签的 token 绑到这条任务上（员工的团队工具据此对回记录）。
        let bound = await rig.registry.token(for: "codex:exec-1")
        XCTAssertNotNil(bound)

        launch.process.deliver(["type": "item.completed", "item": ["id": "item_0", "type": "agent_message", "text": "先看看代码"]])
        launch.process.deliver(["type": "item.completed", "item": ["id": "item_1", "type": "command_execution", "command": "ls"]])
        launch.process.deliver(["type": "item.completed", "item": ["id": "item_2", "type": "agent_message", "text": "改好了，已提交验收"]])
        launch.process.deliver(["type": "turn.completed", "usage": ["input_tokens": 1]])
        launch.process.finish()

        await assertEventually { await self.task(rig)?.status == .completed }
        let done = try await requireTask(rig)
        XCTAssertEqual(done.lastMessage, "改好了，已提交验收")
        XCTAssertNil(done.diagnosis)
        let turnEnds = await rig.store.turnEndCount("codex:exec-1")
        XCTAssertEqual(turnEnds, 1)
        await assertEventually { await rig.connector.status.liveTaskCount == 0 }
        await teardown(rig)
    }

    func testAttendedStartStillUsesAppServer() async throws {
        let rig = await makeRig()
        let outcome = try await rig.connector.start(projectPath: "/tmp/project", prompt: "手机上发的", images: [],
                                                    selection: ModelSelection())
        XCTAssertEqual(outcome.taskId, "codex:thread-1")
        XCTAssertTrue(rig.exec.launches.isEmpty)
        await assertEventually { rig.process.requests(method: "turn/start").count == 1 }
        await teardown(rig)
    }

    func testFailedExecRunReportsSignInDiagnosis() async throws {
        let rig = await makeRig()
        _ = try await startUnattended(rig)
        let process = try XCTUnwrap(rig.exec.latest?.process)
        // 重连途中的 error 不算失败；最后的 turn.failed 才是。
        process.deliver(["type": "error", "message": "Reconnecting... 2/5 (unexpected status 401 Unauthorized: Missing bearer)"])
        process.deliver(["type": "turn.failed", "error": ["message": "unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"]])
        process.finish()

        await assertEventually { await self.task(rig)?.status == .failed }
        let task = try await requireTask(rig)
        XCTAssertEqual(task.diagnosis, .signInExpired)
        XCTAssertTrue(task.lastMessage?.contains("401 Unauthorized") == true)
        await teardown(rig)
    }

    func testExecExitWithoutTurnResultIsFailure() async throws {
        let rig = await makeRig()
        _ = try await startUnattended(rig)
        let process = try XCTUnwrap(rig.exec.latest?.process)
        process.deliver(["type": "error", "message": "You've hit your usage limit. Try again later."])
        process.finish()

        await assertEventually { await self.task(rig)?.status == .failed }
        let task = try await requireTask(rig)
        XCTAssertEqual(task.diagnosis?.kind, .usageLimit)
        await teardown(rig)
    }

    func testInterruptSendsSigintAndRecordsInterrupted() async throws {
        let rig = await makeRig()
        _ = try await startUnattended(rig)
        let process = try XCTUnwrap(rig.exec.latest?.process)

        let outcome = try await rig.connector.interrupt(taskId: "codex:exec-1")
        XCTAssertEqual(outcome.taskId, "codex:exec-1")
        XCTAssertTrue(process.interrupted.current)
        XCTAssertTrue(rig.process.requests(method: "turn/interrupt").isEmpty)

        await assertEventually { await self.task(rig)?.status == .interrupted }
        await teardown(rig)
    }

    func testFollowUpWaitsForExecThenResumesThroughAppServer() async throws {
        let rig = await makeRig(exec: FakeCodexExecLauncher(threadId: "thread-1"))
        _ = try await startUnattended(rig)
        let process = try XCTUnwrap(rig.exec.latest?.process)

        do {
            _ = try await rig.connector.followUp(taskId: "codex:thread-1", prompt: "顺便加个测试")
            XCTFail("exec 这一轮还在跑，续聊应当被拒")
        } catch let error as ConnectorError {
            XCTAssertTrue(error.message.contains("结束后再续聊"))
        }

        process.deliver(["type": "turn.completed"])
        process.finish()
        await assertEventually { await self.task(rig, "codex:thread-1")?.status == .completed }

        // 跑完之后手机续聊照常：app-server `thread/resume` 再 `turn/start`（exec 线程没在 app-server 里加载过）。
        _ = try await rig.connector.followUp(taskId: "codex:thread-1", prompt: "顺便加个测试")
        await assertEventually { rig.process.requests(method: "turn/start").count == 1 }
        XCTAssertEqual(rig.process.requests(method: "thread/resume").count, 1)
        XCTAssertEqual(rig.exec.launches.count, 1)
        await teardown(rig)
    }

    func testExecThatNeverStartsAThreadThrows() async throws {
        let exec = FakeCodexExecLauncher()
        exec.script.withLock { $0 = [["type": "error", "message": "failed to load configuration: bad toml"]] }
        exec.exitsAfterScript.withLock { $0 = true }
        let rig = await makeRig(exec: exec)
        do {
            _ = try await startUnattended(rig)
            XCTFail("没有 thread.started 应当抛错")
        } catch let error as ConnectorError {
            XCTAssertTrue(error.message.contains("bad toml"))
        }
        let live = await rig.connector.liveThreadIds()
        XCTAssertTrue(live.isEmpty)
        await teardown(rig)
    }

    func testStopEndsRunningExecAsInterrupted() async throws {
        let rig = await makeRig()
        _ = try await startUnattended(rig)
        let process = try XCTUnwrap(rig.exec.latest?.process)
        rig.responder.stop()
        await rig.connector.stop()
        XCTAssertTrue(process.terminated.current)
        let status = await task(rig)?.status
        XCTAssertEqual(status, .interrupted)
    }

    func testAppServerExitDoesNotReleaseExecRun() async throws {
        let rig = await makeRig()
        _ = try await startUnattended(rig)
        rig.process.closeStdout()
        await assertEventually {
            if case .restarting = await rig.connector.status.phase { return true }
            return false
        }
        let status = await task(rig)?.status
        XCTAssertEqual(status, .running)
        let live = await rig.connector.liveThreadIds()
        XCTAssertEqual(live, ["exec-1"])
        let liveCount = await rig.connector.status.liveTaskCount
        XCTAssertEqual(liveCount, 1)
        await teardown(rig)
    }

    // MARK: - 纯函数

    /// 账号池：另一个 Codex 账号经 `CODEX_HOME` 交给 `codex exec`；空串的变量从继承的环境里去掉。
    func testSubprocessLauncherAppliesProcessEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("codex")
        try "#!/bin/sh\nprintf '%s|%s' \"$CODEX_HOME\" \"${HOME-unset}\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let launcher = CodexExecSubprocessLauncher(executablePath: script.path)
        let process = try launcher.launch(arguments: [], workingDirectory: directory.path,
                                          processEnvironment: ["CODEX_HOME": "/tmp/acct", "HOME": ""])
        var output = Data()
        while let chunk = try await process.readStdout() { output.append(chunk) }
        _ = await process.waitForExit()
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "/tmp/acct|unset")
    }

    func testEventParsing() {
        func parse(_ text: String) -> CodexExecEvent? { CodexExecEvent.parse(Data(text.utf8)) }
        XCTAssertEqual(parse(#"{"type":"thread.started","thread_id":"t-1"}"#), .threadStarted(threadId: "t-1"))
        XCTAssertEqual(parse(#"{"type":"turn.started"}"#), .turnStarted)
        XCTAssertEqual(parse(#"{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"好"}}"#),
                       .agentMessage("好"))
        XCTAssertEqual(parse(#"{"type":"item.completed","item":{"id":"i","type":"reasoning","text":"想"}}"#), .other)
        XCTAssertEqual(parse(#"{"type":"turn.completed","usage":{}}"#), .turnCompleted)
        XCTAssertEqual(parse(#"{"type":"turn.failed","error":{"message":"boom"}}"#), .turnFailed("boom"))
        XCTAssertEqual(parse(#"{"type":"error","message":"Reconnecting... 1/5"}"#), .error("Reconnecting... 1/5"))
        XCTAssertEqual(parse(#"{"type":"item.started","item":{}}"#), .other)
        XCTAssertNil(parse("2026-11-07T18:30:19Z ERROR not json"))
    }

    func testEventsAreReassembledAcrossChunks() async {
        let process = FakeCodexExecProcess()
        let events = CodexExecEvents(process)
        process.deliverRaw(#"{"type":"thread.st"#)
        process.deliverRaw(#"arted","thread_id":"t-9"}"# + "\nnot json\n" + #"{"type":"turn.started"}"#)
        process.deliverRaw("\n" + #"{"type":"turn.completed"}"#)
        process.finish()
        let first = await events.next()
        let second = await events.next()
        let third = await events.next()
        let fourth = await events.next()
        XCTAssertEqual(first, .threadStarted(threadId: "t-9"))
        XCTAssertEqual(second, .turnStarted)
        XCTAssertEqual(third, .turnCompleted, "最后一行没有换行也要认")
        XCTAssertNil(fourth)
    }

    func testTomlStringEscapesForConfigOverrides() {
        XCTAssertEqual(CodexExec.tomlString("a\"b\\c\nd\te"), #""a\"b\\c\nd\te""#)
        XCTAssertEqual(CodexExec.tomlString("中文 · 岗位"), "\"中文 · 岗位\"")
        XCTAssertEqual(CodexExec.tomlString("\u{1}"), #""\u0001""#)
        XCTAssertEqual(CodexExec.tomlValue(.array([.string("mcp")])), #"["mcp"]"#)
        XCTAssertNil(CodexExec.tomlValue(.object([:])))
    }

    func testFailureMessagesMapToDiagnoses() {
        XCTAssertEqual(CodexExec.diagnosis(message: "unexpected status 401 Unauthorized: Missing bearer"), .signInExpired)
        XCTAssertEqual(CodexExec.diagnosis(message: "You've hit your usage limit. Upgrade to Pro")?.kind, .usageLimit)
        XCTAssertNil(CodexExec.diagnosis(message: "stream disconnected before completion"))
        XCTAssertNil(CodexExec.diagnosis(message: nil))
    }
}
