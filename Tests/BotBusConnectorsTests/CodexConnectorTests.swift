import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

// MARK: - 假 app-server 的自动应答器

/// 盯着假进程的 stdin，对约定的方法自动回一条应答。
///
/// 没有它，每个测试都要手动把请求 id 抠出来再 `deliver`，而本 Task 关心的是命令语义，
/// 不是对号本身（那是 Task 6 的测试）。**依然不起任何真实进程、不发一次网络请求。**
final class CodexAutoResponder: @unchecked Sendable {
    typealias Handler = @Sendable (_ params: [String: Any]) -> [String: Any]

    private let process: FakeCodexProcess
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var answered: Set<String> = []
    private var pump: Task<Void, Never>?

    init(_ process: FakeCodexProcess) { self.process = process }

    func on(_ method: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[method] = handler }
    }

    /// 四条命令用得到的全部请求。thread id 与 turn id 递增，测试可预测。
    func installDefaults(threadId: String = "thread-1") {
        let turns = Locked(0)
        on("thread/start") { _ in ["thread": ["id": threadId], "cwd": "/tmp/project"] }
        on("thread/resume") { params in
            ["thread": ["id": params["threadId"] as? String ?? threadId, "preview": "桌面上开的那个线程"],
             "cwd": "/tmp/desktop"]
        }
        on("thread/read") { params in
            ["thread": ["id": params["threadId"] as? String ?? threadId,
                        "cwd": "/tmp/desktop", "preview": "桌面上开的那个线程"]]
        }
        on("turn/start") { _ in
            let index = turns.withLock { current -> Int in
                current += 1
                return current
            }
            return ["turn": ["id": "turn-\(index)", "status": "inProgress"]]
        }
        on("turn/interrupt") { _ in [:] }
    }

    func start() {
        pump = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
    }

    private func tick() {
        for object in process.objects {
            // 只认"请求"：我们自己写回去的应答有 id 没有 method。
            guard let method = object["method"] as? String, let id = object["id"] else { continue }
            let key = "\(method)\u{1}\(id)"
            let handler: Handler? = lock.withLock {
                guard let handler = handlers[method], !answered.contains(key) else { return nil }
                answered.insert(key)
                return handler
            }
            guard let handler else { continue }
            process.deliver(object: ["id": id, "result": handler(object["params"] as? [String: Any] ?? [:])])
        }
    }
}

// MARK: - 测试

final class CodexConnectorTests: XCTestCase {
    private static let agentId = "agent-mac-000000001"

    private struct Rig {
        let launcher: FakeCodexLauncher
        let sleeper: FakeSleeper
        let server: CodexAppServer
        let store: TaskStore
        let connector: CodexConnector
        let process: FakeCodexProcess
        let responder: CodexAutoResponder
        /// 子进程状态的流水账，按发生顺序。菜单栏看到的就是这些。
        let statuses: Locked<[CodexConnector.Status]>
    }

    private func makeRig(installDefaults: Bool = true, tools: AgentToolsConfiguration? = nil,
                         registry: TaskContextRegistry = TaskContextRegistry(),
                         sharedDesktop: Bool = false) async -> Rig {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = CodexAppServer(launcher: launcher,
                                    configuration: CodexAppServer.Configuration(clientName: "BotBusTest",
                                                                                clientVersion: "0.0.0"),
                                    sleeper: sleeper.sleep)
        let store = TaskStore(identity: AgentIdentity(agentId: Self.agentId, name: "本机", appVersion: "1.0"))
        let statuses = Locked<[CodexConnector.Status]>([])
        let connector = CodexConnector(server: server, store: store,
                                       statusObserver: { status in statuses.withLock { $0.append(status) } },
                                       tools: { tools }, registry: registry,
                                       sharedDesktop: sharedDesktop)
        await connector.start()

        var found: FakeCodexProcess?
        await assertEventually {
            guard let latest = launcher.latest else { return false }
            found = latest
            return latest.requests(method: "initialized").count == 1
        }
        let process = found ?? FakeCodexProcess()
        let responder = CodexAutoResponder(process)
        if installDefaults { responder.installDefaults() }
        responder.start()
        return Rig(launcher: launcher, sleeper: sleeper, server: server, store: store,
                   connector: connector, process: process, responder: responder, statuses: statuses)
    }

    private func teardown(_ rig: Rig) async {
        rig.responder.stop()
        await rig.connector.stop()
    }

    func testSharedDesktopLoadedThreadStartsTurnWithoutResume() async throws {
        let rig = await makeRig(sharedDesktop: true)
        rig.responder.on("thread/loaded/list") { _ in ["data": ["desk-1"]] }
        let outcome = try await rig.connector.followUp(taskId: "codex:desk-1", prompt: "继续")
        XCTAssertEqual(outcome.taskId, "codex:desk-1")
        XCTAssertEqual(rig.process.requests(method: "thread/loaded/list").count, 1)
        XCTAssertEqual(rig.process.requests(method: "thread/resume").count, 0)
        XCTAssertEqual(rig.process.requests(method: "turn/start").count, 1)
        await teardown(rig)
    }

    func testSharedDesktopPublishesDesktopTurnAndLeavesDesktopToolsAlone() async throws {
        let rig = await makeRig(sharedDesktop: true)
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "desktop-task", "turn": ["id": "desktop-turn"]]])
        await assertEventually { await rig.connector.currentTurnId(threadId: "desktop-task") == "desktop-turn" }
        let record = try await requireTask(rig, "codex:desktop-task")
        XCTAssertTrue(record.controllable)
        rig.process.deliver(object: ["id": 81, "method": "item/tool/call",
                                     "params": ["threadId": "desktop-task", "turnId": "desktop-turn"]])
        await assertEventually { await rig.server.pendingServerRequests().count == 1 }
        XCTAssertNil(reply(rig, id: 81), "桌面工具调用必须留给桌面处理")
        await teardown(rig)
    }

    func testSharedDesktopUsesThreadStartedMetadataBeforeObserverIndexesTask() async throws {
        let rig = await makeRig(sharedDesktop: true)
        rig.process.deliver(object: ["method": "thread/started",
                                     "params": ["thread": ["id": "new-desktop-task",
                                                           "cwd": "/tmp/my-project",
                                                           "preview": "桌面新会话",
                                                           "model": "gpt-6-sol",
                                                           "reasoningEffort": "high"]]])
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "new-desktop-task", "turn": ["id": "turn"]]])
        await assertEventually { await self.task(rig, "codex:new-desktop-task")?.status == .running }
        let record = try await requireTask(rig, "codex:new-desktop-task")
        XCTAssertEqual(record.projectPath, "/tmp/my-project")
        XCTAssertEqual(record.title, "桌面新会话")
        XCTAssertEqual(record.model, "gpt-6-sol")
        XCTAssertEqual(record.effort, "high")
        XCTAssertEqual(rig.process.requests(method: "thread/read").count, 1, "新一轮开始时刷新桌面模型")
        await teardown(rig)
    }

    func testSharedDesktopReadsMetadataWhenAttachingMidTurn() async throws {
        let rig = await makeRig(sharedDesktop: true)
        rig.responder.on("thread/read") { params in
            ["thread": ["id": params["threadId"] as? String ?? "",
                        "cwd": "/tmp/desktop", "preview": "桌面上开的那个线程",
                        "model": "gpt-6-astra", "reasoningEffort": "xhigh"]]
        }
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "existing-desktop-task", "turn": ["id": "turn"]]])
        await assertEventually { await self.task(rig, "codex:existing-desktop-task")?.projectPath == "/tmp/desktop" }
        let record = try await requireTask(rig, "codex:existing-desktop-task")
        XCTAssertEqual(record.title, "桌面上开的那个线程")
        XCTAssertEqual(record.model, "gpt-6-astra")
        XCTAssertEqual(record.effort, "xhigh")
        XCTAssertEqual(rig.process.requests(method: "thread/read").count, 2, "接入与新一轮各读一次")
        await teardown(rig)
    }

    func testSharedDesktopRefreshesModelWhenDesktopChangesItBetweenTurns() async throws {
        let rig = await makeRig(sharedDesktop: true)
        let current = Locked((model: "gpt-6-sol", effort: "high"))
        rig.responder.on("thread/read") { params in
            let model = current.current
            return ["thread": ["id": params["threadId"] as? String ?? "",
                               "cwd": "/tmp/desktop", "model": model.model,
                               "reasoningEffort": model.effort]]
        }
        rig.process.deliver(object: ["method": "thread/started",
                                     "params": ["thread": ["id": "switching-desktop-task", "cwd": "/tmp/desktop",
                                                           "model": "gpt-6-sol", "reasoningEffort": "high"]]])
        await assertEventually { await self.task(rig, "codex:switching-desktop-task")?.model == "gpt-6-sol" }

        current.withLock { $0 = (model: "gpt-6-astra", effort: "xhigh") }
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "switching-desktop-task", "turn": ["id": "next-turn"]]])
        await assertEventually { await self.task(rig, "codex:switching-desktop-task")?.model == "gpt-6-astra" }
        let record = try await requireTask(rig, "codex:switching-desktop-task")
        XCTAssertEqual(record.effort, "xhigh")
        await teardown(rig)
    }

    func testSharedDesktopFollowUpSteersActiveDesktopTurn() async throws {
        let rig = await makeRig(sharedDesktop: true)
        rig.responder.on("turn/steer") { _ in [:] }
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "desktop-task", "turn": ["id": "desktop-turn"]]])
        await assertEventually { await rig.connector.currentTurnId(threadId: "desktop-task") == "desktop-turn" }
        _ = try await rig.connector.followUp(taskId: "codex:desktop-task", prompt: "补充说明")
        XCTAssertEqual(params(rig, method: "turn/steer")?["expectedTurnId"] as? String, "desktop-turn")
        XCTAssertEqual(rig.process.requests(method: "turn/start").count, 0)
        XCTAssertEqual(rig.process.requests(method: "thread/resume").count, 0)
        await teardown(rig)
    }

    func testSharedDesktopResolutionClearsPhoneApproval() async throws {
        let rig = await makeRig(sharedDesktop: true)
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "desktop-task", "turn": ["id": "desktop-turn"]]])
        await assertEventually { await rig.connector.currentTurnId(threadId: "desktop-task") == "desktop-turn" }
        rig.process.deliver(object: ["id": 82, "method": "item/commandExecution/requestApproval",
                                     "params": ["threadId": "desktop-task", "turnId": "desktop-turn", "command": "pwd"]])
        await assertEventually { await self.task(rig, "codex:desktop-task")?.pendingRequest != nil }
        rig.process.deliver(object: ["method": "serverRequest/resolved",
                                     "params": ["threadId": "desktop-task", "requestId": 82]])
        await assertEventually { await self.task(rig, "codex:desktop-task")?.pendingRequest == nil }
        let pending = await rig.server.pendingServerRequest(key: "#82")
        XCTAssertNil(pending)
        await teardown(rig)
    }

    /// 写出去的请求里某个方法的 params。
    private func params(_ rig: Rig, method: String, at index: Int = 0) -> [String: Any]? {
        let requests = rig.process.requests(method: method)
        guard requests.indices.contains(index) else { return nil }
        return requests[index]["params"] as? [String: Any]
    }

    /// 我们回给服务端请求的那些帧（有 id、没有 method）。
    private func replies(_ rig: Rig) -> [[String: Any]] {
        rig.process.objects.filter { $0["method"] == nil && $0["id"] != nil }
    }

    private func reply(_ rig: Rig, id: Any) -> [String: Any]? {
        replies(rig).last { "\($0["id"]!)" == "\(id)" }
    }

    private func task(_ rig: Rig, _ id: String = "codex:thread-1") async -> TaskRecord? {
        await rig.store.task(id: id)
    }

    /// `XCTUnwrap` 的参数是 autoclosure，塞不进 await：先把记录取回来再解包。
    private func requireTask(_ rig: Rig, _ id: String = "codex:thread-1",
                             file: StaticString = #filePath, line: UInt = #line) async throws -> TaskRecord {
        let record = await task(rig, id)
        return try XCTUnwrap(record, "本机没有任务 \(id)", file: file, line: line)
    }

    // MARK: 命令映射（spec 6.1）

    func testStartTaskCreatesThreadThenStartsTurn() async throws {
        let rig = await makeRig()
        let outcome = try await rig.connector.start(projectPath: "/tmp/project", prompt: "帮我把测试补齐")

        XCTAssertEqual(outcome.taskId, "codex:thread-1")
        XCTAssertTrue(outcome.retainsLiveOwnership, "命令返回不等于轮次结束，所有权不能跟着还回去")

        // 顺序：握手 → thread/start → turn/start。握手完顺手问一次 `model/list`（协议 3.2），与命令无关。
        let methods = rig.process.objects.compactMap { $0["method"] as? String }.filter { $0 != "model/list" }
        XCTAssertEqual(methods, ["initialize", "initialized", "thread/start", "turn/start"])
        XCTAssertEqual(params(rig, method: "thread/start")?["cwd"] as? String, "/tmp/project")

        let turn = try XCTUnwrap(params(rig, method: "turn/start"))
        XCTAssertEqual(turn["threadId"] as? String, "thread-1")
        let input = try XCTUnwrap(turn["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "text")
        XCTAssertEqual(input[0]["text"] as? String, "帮我把测试补齐")

        let record = try await requireTask(rig)
        XCTAssertEqual(record.status, .running)
        XCTAssertEqual(record.title, "帮我把测试补齐")
        XCTAssertEqual(record.projectPath, "/tmp/project")
        XCTAssertEqual(record.projectName, "project")
        XCTAssertEqual(record.origin, .watch)
        XCTAssertEqual(record.agentId, Self.agentId)
        XCTAssertTrue(record.controllable)
        await teardown(rig)
    }

    func testFollowUpResumesThreadWhenNotLoaded() async throws {
        let rig = await makeRig()
        // 只读观察先看到一个桌面线程。
        await rig.store.upsert(TaskRecord(id: "codex:desk-1", agentId: Self.agentId, source: .codex,
                                          title: "桌面上开的那个", projectPath: "/tmp/desktop",
                                          projectName: "desktop", status: .completed, origin: .desktop,
                                          controllable: true,
                                          startedAt: ProtocolJSON.timestamp(), updatedAt: ProtocolJSON.timestamp()))

        let first = try await rig.connector.followUp(taskId: "codex:desk-1", prompt: "接着改")
        XCTAssertEqual(first.taskId, "codex:desk-1")
        XCTAssertEqual(rig.process.requests(method: "thread/resume").count, 1, "线程不在本进程里，必须先 resume")
        XCTAssertEqual(params(rig, method: "thread/resume")?["threadId"] as? String, "desk-1")
        XCTAssertEqual(rig.process.requests(method: "turn/start").count, 1)
        // resume 必须排在 turn/start 前面。
        let methods = rig.process.objects.compactMap { $0["method"] as? String }
        XCTAssertEqual(Array(methods.suffix(2)), ["thread/resume", "turn/start"])

        let record = try await requireTask(rig, "codex:desk-1")
        XCTAssertEqual(record.status, .running)
        XCTAssertEqual(record.origin, .desktop, "接管来的线程仍然算桌面发起")
        XCTAssertEqual(record.projectPath, "/tmp/desktop")

        // 第二次续聊：线程已经在本进程里了，不该再 resume 一次。
        _ = try await rig.connector.followUp(taskId: "codex:desk-1", prompt: "再改一点")
        XCTAssertEqual(rig.process.requests(method: "thread/resume").count, 1, "已加载的线程不再 resume")
        XCTAssertEqual(rig.process.requests(method: "turn/start").count, 2)
        await teardown(rig)
    }

    // MARK: 模型与思考强度（协议 3.2）

    private static let modelList: [String: Any] = ["data": [
        ["id": "gpt-6-sol", "displayName": "GPT-6-Sol", "hidden": false, "isDefault": true,
         "supportedReasoningEfforts": [["reasoningEffort": "low", "description": ""],
                                       ["reasoningEffort": "high", "description": ""]],
         "defaultReasoningEffort": "low"],
        ["id": "gpt-5.5", "displayName": "GPT-5.5", "hidden": false, "isDefault": false,
         "supportedReasoningEfforts": [["reasoningEffort": "xhigh", "description": ""]],
         "defaultReasoningEffort": "xhigh"],
        ["id": "internal-preview", "displayName": "Hidden", "hidden": true, "isDefault": false,
         "supportedReasoningEfforts": [], "defaultReasoningEffort": "low"],
    ], "nextCursor": NSNull()]

    func testModelListIsReportedWithoutHiddenModels() async throws {
        let rig = await makeRig()
        rig.responder.on("model/list") { _ in Self.modelList }
        await assertEventually { rig.store.connectors.models(for: .codex)?.count == 2 }
        let models = try XCTUnwrap(rig.store.connectors.models(for: .codex))
        XCTAssertEqual(models.map(\.id), ["gpt-6-sol", "gpt-5.5"], "hidden 的模型不给手机选")
        XCTAssertEqual(models[0].efforts, ["low", "high"])
        XCTAssertEqual(models[0].defaultEffort, "low")
        await teardown(rig)
    }

    func testFollowUpSwitchesModelThroughTurnStartAndReportsIt() async throws {
        let rig = await makeRig()
        rig.responder.on("model/list") { _ in Self.modelList }
        rig.responder.on("thread/resume") { params in
            ["thread": ["id": params["threadId"] as? String ?? ""], "cwd": "/tmp/desktop",
             "model": "gpt-6-sol", "reasoningEffort": "high"]
        }
        await assertEventually { rig.store.connectors.models(for: .codex) != nil }

        _ = try await rig.connector.followUp(taskId: "codex:desk-1", prompt: "接着改")
        var record = try await requireTask(rig, "codex:desk-1")
        XCTAssertEqual(record.model, "gpt-6-sol", "resume 应答里的模型要报给手机")
        XCTAssertEqual(record.effort, "high")
        XCTAssertNil(params(rig, method: "turn/start")?["model"], "没换就不带")

        _ = try await rig.connector.followUp(taskId: "codex:desk-1", prompt: "换个模型再跑",
                                             images: [], selection: ModelSelection(model: "gpt-5.5", effort: "xhigh"))
        let turn = try XCTUnwrap(params(rig, method: "turn/start", at: 1))
        XCTAssertEqual(turn["model"] as? String, "gpt-5.5")
        XCTAssertEqual(turn["effort"] as? String, "xhigh")
        record = try await requireTask(rig, "codex:desk-1")
        XCTAssertEqual(record.model, "gpt-5.5")
        XCTAssertEqual(record.effort, "xhigh")

        do {
            _ = try await rig.connector.followUp(taskId: "codex:desk-1", prompt: "再换",
                                                 images: [], selection: ModelSelection(effort: "low"))
            XCTFail("GPT-5.5 没有 low 这档，应该当场拒绝")
        } catch {
            XCTAssertTrue("\(error)".contains("low"), "\(error)")
        }
        XCTAssertEqual(rig.process.requests(method: "turn/start").count, 2, "拒绝的续聊不发 turn/start")
        await teardown(rig)
    }

    func testStartTaskSendsTheChosenModelWithTheFirstTurn() async throws {
        let rig = await makeRig()
        rig.responder.on("model/list") { _ in Self.modelList }
        await assertEventually { rig.store.connectors.models(for: .codex) != nil }

        do {
            _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "开始", images: [],
                                              selection: ModelSelection(model: "gpt-9"))
            XCTFail("列表里没有的模型应该当场拒绝")
        } catch {
            XCTAssertTrue("\(error)".contains("gpt-9"), "\(error)")
        }
        XCTAssertTrue(rig.process.requests(method: "thread/start").isEmpty, "选错了不先建空线程")

        let outcome = try await rig.connector.start(projectPath: "/tmp/project", prompt: "开始", images: [],
                                                    selection: ModelSelection(model: "gpt-5.5", effort: "xhigh"))
        let turn = try XCTUnwrap(params(rig, method: "turn/start"))
        XCTAssertEqual(turn["model"] as? String, "gpt-5.5")
        XCTAssertEqual(turn["effort"] as? String, "xhigh")
        let record = try await requireTask(rig, outcome.taskId)
        XCTAssertEqual(record.model, "gpt-5.5")
        XCTAssertEqual(record.effort, "xhigh")
        await teardown(rig)
    }

    func testInterruptCallsTurnInterrupt() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "跑个长任务")

        // 还不知道轮次 id 时不能瞎发：明确失败，别让 app-server 报 -32600。
        do {
            _ = try await rig.connector.interrupt(taskId: "codex:thread-1")
            XCTFail("没有正在进行的轮次时 interrupt 应该失败")
        } catch {
            XCTAssertTrue("\(error)".contains("轮次"), "错误里要说清是为什么：\(error)")
        }

        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "thread-1", "turn": ["id": "turn-1"]]])
        // 等轮次 id 真的记上：任务状态本来就已经是 running，拿它当条件等于没等。
        await assertEventually { await rig.connector.currentTurnId(threadId: "thread-1") == "turn-1" }

        let outcome = try await rig.connector.interrupt(taskId: "codex:thread-1")
        XCTAssertEqual(outcome.taskId, "codex:thread-1")
        XCTAssertTrue(outcome.retainsLiveOwnership, "中断只是发出去了，轮次要等 turn/completed 才算结束")
        let interrupt = try XCTUnwrap(params(rig, method: "turn/interrupt"))
        XCTAssertEqual(interrupt["threadId"] as? String, "thread-1")
        XCTAssertEqual(interrupt["turnId"] as? String, "turn-1")
        await teardown(rig)
    }

    // MARK: 合并并结束（协议 3.4）

    func testDiscardArchivesTheThread() async throws {
        let rig = await makeRig()
        rig.responder.on("thread/archive") { _ in [:] }
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "改完就合并")
        await rig.connector.discard(taskId: "codex:thread-1")
        let archive = try XCTUnwrap(params(rig, method: "thread/archive"))
        XCTAssertEqual(archive["threadId"] as? String, "thread-1")
        await teardown(rig)
    }

    func testDiscardIgnoresForeignTaskIds() async throws {
        let rig = await makeRig()
        await rig.connector.discard(taskId: "claude:session-1")
        XCTAssertNil(params(rig, method: "thread/archive"))
        await teardown(rig)
    }

    // MARK: 审批

    func testApproveRepliesToPendingServerRequest() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "删点东西")
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "thread-1", "turn": ["id": "turn-1"]]])

        let events = await rig.store.events()
        let notified = Locked<[Notify]>([])
        let collector = Task {
            for await event in events where event.kind == .notify {
                if let notify = event.notify { notified.withLock { $0.append(notify) } }
            }
        }

        rig.process.deliver(object: ["id": 5, "method": "item/commandExecution/requestApproval",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "i1",
                                                "kind": "command", "command": "rm -rf build",
                                                "cwd": "/tmp/project", "startedAtMs": 1]])

        await assertEventually { await self.task(rig)?.status == .waitingApproval }
        let waiting = try await requireTask(rig)
        let pending = try XCTUnwrap(waiting.pendingRequest)
        XCTAssertEqual(pending.id, "#5", "PendingRequest.id 就是 CodexServerRequest.key")
        XCTAssertEqual(pending.kind, .command)
        XCTAssertTrue(pending.summary.contains("rm -rf build"))

        await assertEventually { notified.current.contains { $0.category == .taskApproval } }
        let notify = try XCTUnwrap(notified.current.first { $0.category == .taskApproval })
        XCTAssertEqual(notify.requestId, "#5")
        XCTAssertEqual(notify.taskId, "codex:thread-1")

        let outcome = try await rig.connector.approve(taskId: "codex:thread-1", requestId: "#5", decision: .allow)
        XCTAssertTrue(outcome.retainsLiveOwnership)
        let sent = try XCTUnwrap(reply(rig, id: 5))
        XCTAssertEqual((sent["result"] as? [String: Any])?["decision"] as? String, "accept")
        XCTAssertNil(sent["error"])

        await assertEventually { await self.task(rig)?.pendingRequest == nil }
        let resumed = try await requireTask(rig)
        XCTAssertEqual(resumed.status, .running, "批准之后轮次接着跑")
        let stillPending = await rig.server.pendingServerRequests()
        XCTAssertTrue(stillPending.isEmpty)
        collector.cancel()
        await teardown(rig)
    }

    func testDenyMapsToDeclineDecision() async throws {
        // 决策值的全集与映射，不需要起进程。
        XCTAssertEqual(Set(CodexApprovalDecision.allCases.map(\.rawValue)),
                       ["accept", "acceptForSession", "decline", "cancel"])
        XCTAssertEqual(CodexApprovalDecision(.allow), .accept)
        XCTAssertEqual(CodexApprovalDecision(.deny), .decline)

        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "删点东西")
        rig.process.deliver(object: ["id": 7, "method": "item/commandExecution/requestApproval",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "i1",
                                                "command": "rm -rf /", "cwd": "/tmp/project", "startedAtMs": 1]])
        await assertEventually { await self.task(rig)?.status == .waitingApproval }

        _ = try await rig.connector.approve(taskId: "codex:thread-1", requestId: "#7", decision: .deny)
        let sent = try XCTUnwrap(reply(rig, id: 7))
        XCTAssertEqual((sent["result"] as? [String: Any])?["decision"] as? String, "decline")
        await teardown(rig)
    }

    func testFileChangeApprovalCarriesDiffCachedFromItemStarted() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "改个文件")

        // diff 只在 item/started 里出现过一次。
        rig.process.deliver(object: ["method": "item/started",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1",
                                                "item": ["id": "i9", "type": "fileChange", "status": "inProgress",
                                                         "changes": [["path": "/tmp/project/a.swift",
                                                                      "kind": "update",
                                                                      "diff": "@@ -1 +1 @@\n-a\n+b\n"]]]]])
        // 审批请求本身不带 diff。
        rig.process.deliver(object: ["id": 11, "method": "item/fileChange/requestApproval",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1",
                                                "itemId": "i9", "startedAtMs": 2]])

        await assertEventually { await self.task(rig)?.pendingRequest?.kind == .fileChange }
        let changing = try await requireTask(rig)
        let pending = try XCTUnwrap(changing.pendingRequest)
        XCTAssertEqual(pending.id, "#11")
        XCTAssertTrue(pending.summary.contains("a.swift"), "摘要里要看得出改了哪个文件：\(pending.summary)")
        let detail = try XCTUnwrap(pending.detail)
        XCTAssertTrue(detail.contains("+b"), "补丁要从 item/started 的缓存里补进来：\(detail)")

        _ = try await rig.connector.approve(taskId: "codex:thread-1", requestId: "#11", decision: .allow)
        let sent = try XCTUnwrap(reply(rig, id: 11))
        XCTAssertEqual((sent["result"] as? [String: Any])?["decision"] as? String, "accept")
        await teardown(rig)
    }

    func testApprovalPendingRequestSurvivesUntilAnsweredOrTurnInterrupted() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "跑一下")
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "thread-1", "turn": ["id": "turn-1"]]])
        rig.process.deliver(object: ["id": 21, "method": "item/permissions/requestApproval",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "i1",
                                                "environmentId": NSNull(), "startedAtMs": 1,
                                                "cwd": "/tmp/project", "reason": "需要写盘",
                                                "permissions": ["network": ["enabled": true],
                                                                "fileSystem": NSNull()]]])
        await assertEventually { await self.task(rig)?.pendingRequest?.kind == .permission }
        let before = rig.process.written.current.count

        // Agent 不设超时：挂着就是挂着，谁都不许替用户回答。
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(rig.process.written.current.count, before, "审批请求不能被自动回复")
        let stillWaiting = try await requireTask(rig)
        XCTAssertEqual(stillWaiting.status, .waitingApproval)

        // 轮次被中断：Task 6 静默丢弃这一轮的请求，连接器要把待审批从任务上摘掉。
        rig.process.deliver(object: ["method": "turn/completed",
                                     "params": ["threadId": "thread-1",
                                                "turn": ["id": "turn-1", "status": "interrupted"]]])
        await assertEventually { await self.task(rig)?.pendingRequest == nil }
        let cleared = try await requireTask(rig)
        XCTAssertEqual(cleared.status, .interrupted)
        XCTAssertEqual(rig.process.written.current.count, before, "丢弃不是回答：一个字节都不写回去")
        await teardown(rig)
    }

    /// 协议 3.7：上一轮额度用完的原因只属于那一次 failed；新一轮开始后再因 systemError 失败，不能还挂着旧原因。
    func testNewTurnDropsThePreviousFailureDiagnosis() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "跑一下")
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "thread-1", "turn": ["id": "turn-1"]]])
        rig.process.deliver(object: ["method": "turn/completed",
                                     "params": ["threadId": "thread-1",
                                                "turn": ["id": "turn-1", "status": "failed",
                                                         "error": ["message": "You've hit your usage limit.",
                                                                   "codexErrorInfo": "usageLimitExceeded"]]]])
        await assertEventually { await self.task(rig)?.status == .failed }
        let limited = try await requireTask(rig)
        XCTAssertEqual(limited.diagnosis, .usageLimit())

        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "thread-1", "turn": ["id": "turn-2"]]])
        await assertEventually { await self.task(rig)?.status == .running }
        rig.process.deliver(object: ["method": "thread/status/changed",
                                     "params": ["threadId": "thread-1", "status": ["type": "systemError"]]])
        await assertEventually { await self.task(rig)?.status == .failed }
        let failedAgain = try await requireTask(rig)
        XCTAssertNil(failedAgain.diagnosis)
        await teardown(rig)
    }

    func testStaleApproveIsRejectedWithReasonInsteadOfHanging() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "跑一下")
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "thread-1", "turn": ["id": "turn-1"]]])
        rig.process.deliver(object: ["id": 31, "method": "item/commandExecution/requestApproval",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "i1",
                                                "command": "ls", "cwd": "/tmp/project", "startedAtMs": 1]])
        await assertEventually { await self.task(rig)?.pendingRequest != nil }

        // 轮次结束 → Task 6 丢掉这条请求。手机上那颗按钮已经没有对端了。
        rig.process.deliver(object: ["method": "turn/completed",
                                     "params": ["threadId": "thread-1",
                                                "turn": ["id": "turn-1", "status": "completed"]]])
        await assertEventually { await rig.server.pendingServerRequests().isEmpty }

        // 走完整条命令链路：客户端拿到的是 ok:false 加一句人话，不是挂住也不是崩。
        let dispatcher = CommandDispatcher(store: rig.store, connectors: [rig.connector])
        let result = await dispatcher.handle(Command(createdAt: ProtocolJSON.timestamp(), agentId: Self.agentId,
                                                     kind: .approve,
                                                     approve: Command.Approve(taskId: "codex:thread-1",
                                                                              requestId: "#31",
                                                                              decision: .allow)))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.taskId, "codex:thread-1")
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.contains("#31"), "错误里要带上请求 id：\(error)")
        XCTAssertTrue(error.contains("失效"), "要说清楚是为什么失效：\(error)")
        XCTAssertNil(reply(rig, id: 31), "失效的请求不该被回写")
        await teardown(rig)
    }

    // MARK: 非审批的服务端请求：必须回，否则线程挂死

    func testNonApprovalServerRequestsAreAnsweredSoTheThreadDoesNotHang() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "跑一下")

        rig.process.deliver(object: ["id": 41, "method": "item/tool/call",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1",
                                                "name": "browser", "arguments": [:]]])
        rig.process.deliver(object: ["id": 42, "method": "account/chatgptAuthTokens/refresh",
                                     "params": [:]])
        rig.process.deliver(object: ["id": 43, "method": "attestation/generate", "params": [:]])
        rig.process.deliver(object: ["id": 44, "method": "mcpServer/elicitation/request",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1",
                                                "serverName": "some-mcp", "mode": "form",
                                                "message": "要不要授权？", "requestedSchema": [:]]])
        rig.process.deliver(object: ["id": 45, "method": "future/unheardOf",
                                     "params": ["threadId": "thread-1"]])

        await assertEventually { await rig.server.pendingServerRequests().isEmpty && self.replies(rig).count >= 5 }

        // 造不出凭据、造不出工具输出的，明确回 JSON-RPC 错误。
        for id in [41, 42, 43, 45] {
            let sent = try XCTUnwrap(reply(rig, id: id), "id=\(id) 没有被回答，codex 会一直等")
            let error = try XCTUnwrap(sent["error"] as? [String: Any], "id=\(id) 应该回错误")
            XCTAssertEqual(error["code"] as? Int, CodexConnector.unsupportedRequestCode)
            XCTAssertNil(sent["result"])
        }
        // 协议里有"拒绝"这个值的，用协议自己的拒绝，别让对端把它当成传输故障。
        let elicitation = try XCTUnwrap(reply(rig, id: 44))
        XCTAssertEqual((elicitation["result"] as? [String: Any])?["action"] as? String, "decline")
        XCTAssertNil(elicitation["error"])

        // 一条都不该冒充审批挂到任务上。
        let untouched = try await requireTask(rig)
        XCTAssertNil(untouched.pendingRequest)
        XCTAssertEqual(untouched.status, .running)
        await teardown(rig)
    }

    func testUserInputRequestBecomesWaitingInputAndFollowUpAnswersIt() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "问我点什么")
        let turnStartsBefore = rig.process.requests(method: "turn/start").count

        let events = await rig.store.events()
        let notified = Locked<[Notify]>([])
        let collector = Task {
            for await event in events where event.kind == .notify {
                if let notify = event.notify { notified.withLock { $0.append(notify) } }
            }
        }

        rig.process.deliver(object: ["id": 51, "method": "item/tool/requestUserInput",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "i1",
                                                "isBlocking": true, "autoResolutionMs": NSNull(),
                                                "questions": [["id": "q1", "header": "部署到哪",
                                                               "question": "生产还是预发？",
                                                               "isOther": false, "isSecret": false,
                                                               "options": NSNull()]]]])

        await assertEventually { await self.task(rig)?.status == .waitingInput }
        let asking = try await requireTask(rig)
        let pending = try XCTUnwrap(asking.pendingRequest)
        XCTAssertEqual(pending.kind, .input)
        XCTAssertEqual(pending.question, "生产还是预发？")
        await assertEventually { notified.current.contains { $0.category == .taskInput } }

        // 续聊就是那条回答：不开新轮次，直接回掉挂着的请求。
        let outcome = try await rig.connector.followUp(taskId: "codex:thread-1", prompt: "预发")
        XCTAssertEqual(outcome.taskId, "codex:thread-1")
        let sent = try XCTUnwrap(reply(rig, id: 51))
        let answers = try XCTUnwrap((sent["result"] as? [String: Any])?["answers"] as? [String: Any])
        XCTAssertEqual((answers["q1"] as? [String: Any])?["answers"] as? [String], ["预发"])
        XCTAssertEqual(rig.process.requests(method: "turn/start").count, turnStartsBefore,
                       "回答挂起的提问不该另起一轮")
        await assertEventually { await self.task(rig)?.pendingRequest == nil }
        collector.cancel()
        await teardown(rig)
    }

    /// 协议 2.14：带选项的提问转成 `questions`，手机点选的答案经 approve 按问题 id 回过去。
    func testUserInputOptionsBecomeQuestionsAndApproveCarriesAnswers() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "问我点什么")
        rig.process.deliver(object: ["id": 53, "method": "item/tool/requestUserInput",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "i1",
                                                "isBlocking": true, "autoResolutionMs": NSNull(),
                                                "questions": [["id": "q1", "header": "部署到哪",
                                                               "question": "生产还是预发？",
                                                               "isOther": true, "isSecret": false,
                                                               "options": [["label": "生产", "description": "线上"],
                                                                           ["label": "预发", "description": ""]]]]]])
        await assertEventually { await self.task(rig)?.status == .waitingInput }
        let asking = try await requireTask(rig)
        let pending = try XCTUnwrap(asking.pendingRequest)
        XCTAssertEqual(pending.questions, [PendingQuestion(id: "q1", question: "生产还是预发？", header: "部署到哪",
                                                           options: [PendingOption(label: "生产", description: "线上"),
                                                                     PendingOption(label: "预发")])])

        _ = try await rig.connector.approve(taskId: "codex:thread-1", requestId: pending.id, decision: .allow,
                                            answers: ["q1": ["预发"], "q9": ["没这题"]])
        let sent = try XCTUnwrap(reply(rig, id: 53))
        let answers = try XCTUnwrap((sent["result"] as? [String: Any])?["answers"] as? [String: Any])
        XCTAssertEqual(Array(answers.keys), ["q1"])
        XCTAssertEqual((answers["q1"] as? [String: Any])?["answers"] as? [String], ["预发"])
        await assertEventually { await self.task(rig)?.pendingRequest == nil }
        await teardown(rig)
    }

    // MARK: 所有权与状态

    func testLiveTaskClaimsOwnershipAndReleasesOnCompletion() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "跑一下")
        var owner = await rig.store.owner(of: "codex:thread-1")
        XCTAssertEqual(owner, .live, "连接器开始驱动线程就要挡住只读观察")

        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "thread-1", "turn": ["id": "turn-1"]]])
        await assertEventually { await self.task(rig)?.status == .running }

        // 轮次进行中，只读观察报的东西不许改写它。
        await rig.store.reconcile(source: .codex, tasks: [
            TaskRecord(id: "codex:thread-1", agentId: Self.agentId, source: .codex, title: "SQLite 里落后的样子",
                       projectPath: "/tmp/project", projectName: "project", status: .idle, origin: .desktop,
                       controllable: true, startedAt: ProtocolJSON.timestamp(),
                       updatedAt: ProtocolJSON.timestamp()),
        ], projects: [])
        let unchanged = try await requireTask(rig)
        XCTAssertEqual(unchanged.status, .running)
        XCTAssertEqual(unchanged.title, "跑一下")

        rig.process.deliver(object: ["method": "item/agentMessage/delta",
                                     "params": ["threadId": "thread-1", "itemId": "m1", "delta": "干"]])
        rig.process.deliver(object: ["method": "item/agentMessage/delta",
                                     "params": ["threadId": "thread-1", "itemId": "m1", "delta": "完了"]])
        await assertEventually { await self.task(rig)?.lastMessage == "干完了" }

        rig.process.deliver(object: ["method": "item/completed",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1",
                                                "item": ["id": "m1", "type": "agentMessage",
                                                         "text": "干完了，测试全绿。", "phase": "final_answer"]]])
        rig.process.deliver(object: ["method": "turn/completed",
                                     "params": ["threadId": "thread-1",
                                                "turn": ["id": "turn-1", "status": "completed"]]])

        await assertEventually { await self.task(rig)?.status == .completed }
        let finished = try await requireTask(rig)
        XCTAssertEqual(finished.lastMessage, "干完了，测试全绿。")
        await assertEventually { await rig.store.owner(of: "codex:thread-1") == .observer }
        owner = await rig.store.owner(of: "codex:thread-1")
        XCTAssertEqual(owner, .observer, "轮次结束就把任务交还给只读观察，别跟 CodexObserver 打架")
        let controlled = await rig.server.controlledThreads()
        XCTAssertFalse(controlled.contains("thread-1"), "交还控制后重启不该再 resume 它")
        await teardown(rig)
    }

    func testTurnFailureSurfacesTheErrorAsLastMessage() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "跑一下")
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "thread-1", "turn": ["id": "turn-1"]]])
        rig.process.deliver(object: ["method": "turn/completed",
                                     "params": ["threadId": "thread-1",
                                                "turn": ["id": "turn-1", "status": "failed",
                                                         "error": ["message": "模型超时"]]]])
        await assertEventually { await self.task(rig)?.status == .failed }
        let failed = try await requireTask(rig)
        XCTAssertEqual(failed.lastMessage, "模型超时")
        await assertEventually { await rig.store.owner(of: "codex:thread-1") == .observer }
        await teardown(rig)
    }

    // MARK: 子进程状态（菜单栏要看得见）

    /// 起进程 → 握手完成，两段状态都得报出来，代数从 1 开始。
    func testStatusGoesFromStartingToReady() async throws {
        let rig = await makeRig()
        await assertEventually { await rig.connector.status.phase == .ready }
        let status = await rig.connector.status
        XCTAssertEqual(status.generation, 1)
        XCTAssertEqual(status.text, "app-server：运行中")
        XCTAssertFalse(status.needsAttention)
        XCTAssertEqual(rig.statuses.current.first?.phase, .starting, "第一声必须是'正在启动'")
        XCTAssertEqual(rig.statuses.current.last?.phase, .ready)
        await teardown(rig)
    }

    /// 子进程死了：菜单栏要立刻说"已退出，3 秒后重启"，重启成功后再回到运行中。
    func testStatusSurfacesDeathAndRestart() async throws {
        let rig = await makeRig()
        await assertEventually { await rig.connector.status.phase == .ready }

        rig.process.closeStdout() // 子进程死了

        await assertEventually { await rig.connector.status.phase == .restarting(after: 3) }
        let dead = await rig.connector.status
        XCTAssertEqual(dead.text, "app-server：已退出，3 秒后重启")
        XCTAssertTrue(dead.needsAttention, "死了等重启必须让用户看见")
        XCTAssertEqual(rig.launcher.count, 1, "3 秒没过就不许重启")

        await assertEventually { rig.sleeper.requested.contains(CodexAppServer.restartDelay) }
        rig.sleeper.release(CodexAppServer.restartDelay)

        await assertEventually { await rig.connector.status.phase == .ready }
        let revived = await rig.connector.status
        XCTAssertEqual(revived.generation, 2)
        XCTAssertEqual(rig.launcher.count, 2, "重启只起一个新进程")
        XCTAssertFalse(revived.needsAttention)
        await teardown(rig)
    }

    /// `stop()` 要真的把子进程终止掉，并且状态回到"未运行"——`CodexAppServer.stop()` 不发 `.exited`，
    /// 全靠连接器自己收这一笔。取消配对与退出 app 走的都是这条路。
    func testStopTerminatesTheSubprocessAndReportsStopped() async throws {
        let rig = await makeRig()
        await assertEventually { await rig.connector.status.phase == .ready }
        await rig.connector.stop()

        XCTAssertTrue(rig.process.terminated.current, "停连接器必须把 codex 子进程也终止掉")
        let status = await rig.connector.status
        XCTAssertEqual(status.phase, .stopped)
        XCTAssertEqual(status.text, "app-server：未运行")
        XCTAssertEqual(status.liveTaskCount, 0)
        let alive = await rig.server.isProcessAlive
        XCTAssertFalse(alive)
        rig.responder.stop()
    }

    /// 停了再起（取消配对之后重新配对）：同一份连接器复用，机器上任何时刻只有一个 codex 子进程，
    /// 上一个已经被终止，不会留在那里。
    func testRestartingTheConnectorDoesNotLeakTheOldSubprocess() async throws {
        let rig = await makeRig()
        await assertEventually { await rig.connector.status.phase == .ready }
        await rig.connector.stop()
        let first = try XCTUnwrap(rig.launcher.processes.first)
        XCTAssertTrue(first.terminated.current)

        await rig.connector.start()
        await assertEventually { rig.launcher.count == 2 }
        // 新进程要自己握手；假进程会自动回 initialize。
        await assertEventually { await rig.connector.status.phase == .ready }
        XCTAssertEqual(rig.launcher.count, 2, "只多出一个子进程，不是两个")
        XCTAssertEqual(rig.launcher.processes.filter { !$0.terminated.current }.count, 1,
                       "同一时刻只能有一个活着的 codex 子进程")
        let status = await rig.connector.status
        XCTAssertEqual(status.generation, 2)

        rig.responder.stop()
        await rig.connector.stop()
    }

    /// 状态里那个"正在驱动几个任务"跟着所有权走：轮次跑完交还给只读观察，数字要落回去。
    func testStatusCountsLiveTasks() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "跑一下")
        await assertEventually { await rig.connector.status.liveTaskCount == 1 }
        let running = await rig.connector.status
        XCTAssertEqual(running.text, "app-server：运行中 · 正在驱动 1 个任务")

        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "thread-1", "turn": ["id": "turn-1"]]])
        rig.process.deliver(object: ["method": "turn/completed",
                                     "params": ["threadId": "thread-1",
                                                "turn": ["id": "turn-1", "status": "completed"]]])
        await assertEventually { await rig.connector.status.liveTaskCount == 0 }
        let idle = await rig.connector.status
        XCTAssertEqual(idle.text, "app-server：运行中")
        await teardown(rig)
    }

    func testNotificationsForUnknownThreadsDoNotInventTasks() async throws {
        let rig = await makeRig()
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "somebody-elses", "turn": ["id": "turn-9"]]])
        try? await Task.sleep(for: .milliseconds(80))
        let snapshot = await rig.store.snapshot()
        XCTAssertTrue(snapshot.tasks.isEmpty, "本连接器没驱动过的线程不该凭空变成任务")
        await teardown(rig)
    }

    // MARK: agent 工具注入（spec 3.2）

    /// 一个真的可执行的假 CLI：`AgentToolsConfiguration.isUsable` 要看到文件存在且可执行。
    private func fakeCLI() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent(fakeCLIName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return cli.path
    }

    func testThreadStartCarriesNoInjectionWithoutTools() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "做个页面")
        let start = try XCTUnwrap(params(rig, method: "thread/start"))
        XCTAssertEqual(Set(start.keys), ["cwd"], "没有配置就与以前完全一样")
        await teardown(rig)
    }

    func testMissingCLIMeansNoInjection() async throws {
        let rig = await makeRig(tools: AgentToolsConfiguration(cliPath: "/nonexistent/botbus",
                                                               toolsURL: "http://127.0.0.1:1"))
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "做个页面")
        let start = try XCTUnwrap(params(rig, method: "thread/start"))
        XCTAssertEqual(Set(start.keys), ["cwd"])
        await teardown(rig)
    }

    func testThreadStartInjectsInstructionsAndDottedConfigAndBindsToken() async throws {
        let cli = try fakeCLI()
        let registry = TaskContextRegistry()
        let rig = await makeRig(tools: AgentToolsConfiguration(cliPath: cli, toolsURL: "http://127.0.0.1:4567"),
                                registry: registry)
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "做个页面")

        let start = try XCTUnwrap(params(rig, method: "thread/start"))
        XCTAssertEqual(start["cwd"] as? String, "/tmp/project")
        let instructions = try XCTUnwrap(start["developerInstructions"] as? String)
        XCTAssertTrue(instructions.contains("sent from the user's phone"))
        XCTAssertTrue(instructions.contains(cli), "说明里要有 CLI 的绝对路径")
        let config = try XCTUnwrap(start["config"] as? [String: Any])
        XCTAssertEqual(config["mcp_servers.botbus.command"] as? String, cli)
        XCTAssertEqual(config["mcp_servers.botbus.args"] as? [String], ["mcp"])
        XCTAssertEqual(config["mcp_servers.botbus.env.BOTBUS_TOOLS_URL"] as? String, "http://127.0.0.1:4567")
        XCTAssertEqual(config["shell_environment_policy.set.BOTBUS_TOOLS_URL"] as? String, "http://127.0.0.1:4567")
        XCTAssertEqual(config["shell_environment_policy.set.BOTBUS_CLI"] as? String, cli)
        // 只写叶子：整张表覆盖会冲掉用户自己的 mcp_servers / shell_environment_policy。
        for key in config.keys {
            XCTAssertFalse(["mcp_servers", "mcp_servers.botbus", "mcp_servers.botbus.env",
                            "shell_environment_policy", "shell_environment_policy.set"].contains(key), key)
        }
        let token = try XCTUnwrap(config["mcp_servers.botbus.env.BOTBUS_TASK_TOKEN"] as? String)
        XCTAssertEqual(config["shell_environment_policy.set.BOTBUS_TASK_TOKEN"] as? String, token)
        let resolved = await registry.resolve(token, wait: 0)
        XCTAssertEqual(resolved, "codex:thread-1", "线程 id 到手就绑定")
        await teardown(rig)
    }

    func testResumeInjectsOnceAndReusesTheTaskToken() async throws {
        let cli = try fakeCLI()
        let registry = TaskContextRegistry()
        let earlier = await registry.issue()
        await registry.bind(earlier, taskId: "codex:desk-1")
        let rig = await makeRig(tools: AgentToolsConfiguration(cliPath: cli, toolsURL: "http://127.0.0.1:4567"),
                                registry: registry)

        _ = try await rig.connector.followUp(taskId: "codex:desk-1", prompt: "接着改")
        let resume = try XCTUnwrap(params(rig, method: "thread/resume"))
        XCTAssertEqual(resume["threadId"] as? String, "desk-1")
        XCTAssertNotNil(resume["developerInstructions"] as? String)
        let config = try XCTUnwrap(resume["config"] as? [String: Any])
        XCTAssertEqual(config["mcp_servers.botbus.env.BOTBUS_TASK_TOKEN"] as? String, earlier,
                       "续聊沿用同一个 token")

        // 已在本代子进程加载：只发 turn/start，不再 resume、不再注入。
        _ = try await rig.connector.followUp(taskId: "codex:desk-1", prompt: "再改一点")
        XCTAssertEqual(rig.process.requests(method: "thread/resume").count, 1)
        XCTAssertEqual(rig.process.requests(method: "turn/start").count, 2)
        let turn = try XCTUnwrap(params(rig, method: "turn/start", at: 1))
        XCTAssertNil(turn["config"])
        let tokens = await registry.tokenCount
        XCTAssertEqual(tokens, 1, "没有另签新 token")
        await teardown(rig)
    }

    // MARK: 手机发图（协议 2.9）

    func testTurnStartParamsPutTextFirstThenLocalImages() {
        let params = CodexConnector.turnStartParams(threadId: "t", text: "看看这两张",
                                                    images: [URL(fileURLWithPath: "/a.jpg"),
                                                             URL(fileURLWithPath: "/b.jpg")])
        XCTAssertEqual(params, [
            "threadId": "t",
            "input": [
                ["type": "text", "text": "看看这两张", "text_elements": .array([])],
                ["type": "localImage", "path": "/a.jpg"],
                ["type": "localImage", "path": "/b.jpg"],
            ],
        ])
    }

    func testTurnStartParamsWithoutTextHasOnlyImages() {
        let params = CodexConnector.turnStartParams(threadId: "t", text: "", images: [URL(fileURLWithPath: "/a.jpg")])
        XCTAssertEqual(params["input"], [["type": "localImage", "path": "/a.jpg"]])
    }

    func testTurnStartParamsWithoutImagesAreUnchanged() {
        XCTAssertEqual(CodexConnector.turnStartParams(threadId: "t", text: "hi"), [
            "threadId": "t",
            "input": [["type": "text", "text": "hi", "text_elements": .array([])]],
        ])
    }

    func testStartWithImagesSendsLocalImages() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "照着这张图做",
                                          images: [URL(fileURLWithPath: "/tmp/in/a.jpg")])
        let input = try XCTUnwrap(params(rig, method: "turn/start")?["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String }, ["text", "localImage"])
        XCTAssertEqual(input[1]["path"] as? String, "/tmp/in/a.jpg")
        await teardown(rig)
    }

    func testStartWithOnlyImagesUsesPlaceholderTitle() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "  ",
                                          images: [URL(fileURLWithPath: "/tmp/in/a.jpg")])
        let record = try await requireTask(rig)
        XCTAssertEqual(record.title, "图片")
        let input = try XCTUnwrap(params(rig, method: "turn/start")?["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String }, ["localImage"])
        await teardown(rig)
    }

    func testFollowUpWithOnlyImagesIsAcceptedButEmptyWithoutImagesIsNot() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "先开个头")
        _ = try await rig.connector.followUp(taskId: "codex:thread-1", prompt: "  ",
                                             images: [URL(fileURLWithPath: "/tmp/in/b.png")])
        let input = try XCTUnwrap(params(rig, method: "turn/start", at: 1)?["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "localImage")
        XCTAssertEqual(input[0]["path"] as? String, "/tmp/in/b.png")

        do {
            _ = try await rig.connector.followUp(taskId: "codex:thread-1", prompt: " ")
            XCTFail("没字也没图不该发出去")
        } catch let error as ConnectorError {
            XCTAssertEqual(error.message, "followUp 的 prompt 是空的")
        }
        await teardown(rig)
    }

    func testFollowUpWithImagesWhileAskingIsRefusedInsteadOfDroppingImages() async throws {
        let rig = await makeRig()
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "问我点什么")
        let turnStartsBefore = rig.process.requests(method: "turn/start").count
        rig.process.deliver(object: ["id": 52, "method": "item/tool/requestUserInput",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "i1",
                                                "isBlocking": true, "autoResolutionMs": NSNull(),
                                                "questions": [["id": "q1", "header": "部署到哪",
                                                               "question": "生产还是预发？",
                                                               "isOther": false, "isSecret": false,
                                                               "options": NSNull()]]]])
        await assertEventually { await self.task(rig)?.status == .waitingInput }

        do {
            _ = try await rig.connector.followUp(taskId: "codex:thread-1", prompt: "预发",
                                                 images: [URL(fileURLWithPath: "/tmp/in/c.jpg")])
            XCTFail("图不能被当成问题的回答丢掉")
        } catch let error as ConnectorError {
            XCTAssertEqual(error.message, "Agent 正在等你回答问题，先回答再发图")
        }
        XCTAssertNil(reply(rig, id: 52), "挂着的提问没被回答")
        XCTAssertEqual(rig.process.requests(method: "turn/start").count, turnStartsBefore)
        await teardown(rig)
    }

    // MARK: 项目级自动批准（协议 3.3）

    func testAutoApprovedProjectAcceptsApprovalsInPhoneTurns() async throws {
        let rig = await makeRig()
        await rig.store.setAutoApprove(true, project: "/tmp/project")
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "跑测试")
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "thread-1", "turn": ["id": "turn-1"]]])

        rig.process.deliver(object: ["id": 5, "method": "item/commandExecution/requestApproval",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "i1",
                                                "command": "make test", "cwd": "/tmp/project"]])
        await assertEventually { self.reply(rig, id: 5) != nil }
        XCTAssertEqual((reply(rig, id: 5)?["result"] as? [String: Any])?["decision"] as? String, "accept")

        // permissions：授出它要的那些，范围只这一轮。
        rig.process.deliver(object: ["id": 6, "method": "item/permissions/requestApproval",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1",
                                                "permissions": ["network": ["enabled": true], "fileSystem": NSNull()]]])
        await assertEventually { self.reply(rig, id: 6) != nil }
        let granted = try XCTUnwrap(reply(rig, id: 6)?["result"] as? [String: Any])
        XCTAssertEqual(granted["scope"] as? String, "turn")
        XCTAssertEqual((granted["permissions"] as? [String: Any])?.keys.sorted(), ["network"])

        let record = try await requireTask(rig)
        XCTAssertEqual(record.status, .running, "放行的审批不挂到任务上")
        XCTAssertNil(record.pendingRequest)
        XCTAssertEqual(record.autoApprove, true)
        await teardown(rig)
    }

    func testUserInputIsNeverAutoApproved() async throws {
        let rig = await makeRig()
        await rig.store.setAutoApprove(true, project: "/tmp/project")
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "问我点什么")
        rig.process.deliver(object: ["id": 54, "method": "item/tool/requestUserInput",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "i1",
                                                "questions": [["id": "q1", "question": "生产还是预发？"]]]])
        await assertEventually { await self.task(rig)?.status == .waitingInput }
        XCTAssertNil(reply(rig, id: 54), "提问照旧交给手机")
        await teardown(rig)
    }

    func testApprovalsInProjectsWithoutTheSettingStillWait() async throws {
        let rig = await makeRig()
        await rig.store.setAutoApprove(true, project: "/tmp/another")
        _ = try await rig.connector.start(projectPath: "/tmp/project", prompt: "跑测试")
        rig.process.deliver(object: ["id": 7, "method": "item/commandExecution/requestApproval",
                                     "params": ["threadId": "thread-1", "turnId": "turn-1", "command": "pwd"]])
        await assertEventually { await self.task(rig)?.status == .waitingApproval }
        XCTAssertNil(reply(rig, id: 7))
        await teardown(rig)
    }

    func testSharedDesktopAutoApprovesOnlyThePhoneTurn() async throws {
        let rig = await makeRig(sharedDesktop: true)
        rig.responder.on("turn/steer") { _ in [:] }
        await rig.store.setAutoApprove(true, project: "/tmp/desktop")

        // 桌面自己的一轮：照旧挂给人。
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "desktop-task", "turn": ["id": "desktop-turn"]]])
        await assertEventually { await rig.connector.currentTurnId(threadId: "desktop-task") == "desktop-turn" }
        rig.process.deliver(object: ["id": 82, "method": "item/commandExecution/requestApproval",
                                     "params": ["threadId": "desktop-task", "turnId": "desktop-turn", "command": "pwd"]])
        await assertEventually { await self.task(rig, "codex:desktop-task")?.pendingRequest?.id == "#82" }
        XCTAssertNil(reply(rig, id: 82), "桌面轮次里的审批不自动放行")
        rig.process.deliver(object: ["method": "serverRequest/resolved",
                                     "params": ["threadId": "desktop-task", "requestId": 82]])
        await assertEventually { await self.task(rig, "codex:desktop-task")?.pendingRequest == nil }

        // 手机插进这一轮之后，剩下的部分算手机的轮次。
        _ = try await rig.connector.followUp(taskId: "codex:desktop-task", prompt: "接着做")
        rig.process.deliver(object: ["id": 83, "method": "item/commandExecution/requestApproval",
                                     "params": ["threadId": "desktop-task", "turnId": "desktop-turn", "command": "ls"]])
        await assertEventually { self.reply(rig, id: 83) != nil }
        XCTAssertEqual((reply(rig, id: 83)?["result"] as? [String: Any])?["decision"] as? String, "accept")

        // 这一轮结束，桌面再起的下一轮又归人管。
        rig.process.deliver(object: ["method": "turn/completed",
                                     "params": ["threadId": "desktop-task",
                                                "turn": ["id": "desktop-turn", "status": "completed"]]])
        await assertEventually { await rig.connector.currentTurnId(threadId: "desktop-task") == nil }
        rig.process.deliver(object: ["method": "turn/started",
                                     "params": ["threadId": "desktop-task", "turn": ["id": "desktop-turn-2"]]])
        await assertEventually { await rig.connector.currentTurnId(threadId: "desktop-task") == "desktop-turn-2" }
        rig.process.deliver(object: ["id": 84, "method": "item/commandExecution/requestApproval",
                                     "params": ["threadId": "desktop-task", "turnId": "desktop-turn-2", "command": "pwd"]])
        await assertEventually { await self.task(rig, "codex:desktop-task")?.pendingRequest?.id == "#84" }
        XCTAssertNil(reply(rig, id: 84))
        await teardown(rig)
    }
}
