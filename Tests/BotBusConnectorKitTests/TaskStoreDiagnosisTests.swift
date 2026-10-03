import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit

final class TaskStoreDiagnosisTests: XCTestCase {
    private static let agentId = "diagnosis-agent"

    private func task(_ status: TaskStatus, diagnosis: FailureDiagnosis? = nil, id: String = "claude:one") -> TaskRecord {
        TaskRecord(id: id, agentId: Self.agentId, source: .claude, title: "t",
                   projectPath: "/Users/me/Documents/p", projectName: "p", status: status,
                   lastMessage: "claude 退出了", origin: .watch, controllable: true,
                   startedAt: "2026-10-03T00:00:00Z", updatedAt: "2026-10-03T00:01:00Z", diagnosis: diagnosis)
    }

    private func store(probe: DirectoryProbe?) -> TaskStore {
        let registry = ConnectorRegistry(descriptors: [
            ConnectorDescriptor(kind: .claude, displayName: "Claude Code", defaultEnabled: true) {
                ConnectorProbe(available: true, status: .ok)
            }
        ])
        return TaskStore(identity: AgentIdentity(agentId: Self.agentId), connectors: registry, directoryProbe: probe)
    }

    private func probe(_ access: DirectoryProbe.Access?, calls: Counter) -> DirectoryProbe {
        DirectoryProbe(timeout: 1, access: { _ in calls.increment(); return access }, folder: { _ in .documents })
    }

    /// 连接器带来的诊断只在 failed 时保留；任务重新跑起来就不再带。
    func testConnectorDiagnosisOnlyOnFailedTasks() async {
        let store = store(probe: nil)
        await store.upsert(task(.running, diagnosis: .notSignedIn))
        let running = await store.task(id: "claude:one")
        XCTAssertNil(running?.diagnosis)
        await store.upsert(task(.failed, diagnosis: .notSignedIn))
        let failed = await store.task(id: "claude:one")
        XCTAssertEqual(failed?.diagnosis, .notSignedIn)
    }

    /// 一轮结束后所有权交还观察者（Codex）：观察者再报同一条 failed（不带诊断）时，连接器认出的原因不能丢；
    /// 重新跑起来才撤掉，之后观察者报的 failed 不再带旧原因。
    func testConnectorDiagnosisSurvivesObserverRefresh() async {
        let store = store(probe: nil)
        await store.reconcile(source: .claude, tasks: [], projects: [])
        await store.upsert(task(.running))
        await store.upsert(task(.failed, diagnosis: .usageLimit()))
        var observed = task(.failed)
        observed.updatedAt = "2026-10-03T00:02:00Z"
        await store.upsert(observed)
        let upserted = await store.task(id: "claude:one")
        XCTAssertEqual(upserted?.diagnosis, .usageLimit())
        observed.updatedAt = "2026-10-03T00:03:00Z"
        await store.reconcile(source: .claude, tasks: [observed], projects: [])
        let reconciled = await store.task(id: "claude:one")
        XCTAssertEqual(reconciled?.updatedAt, "2026-10-03T00:03:00Z")
        XCTAssertEqual(reconciled?.diagnosis, .usageLimit())
        await store.upsert(task(.running))
        let running = await store.task(id: "claude:one")
        XCTAssertNil(running?.diagnosis)
        await store.upsert(observed)
        let failedAgain = await store.task(id: "claude:one")
        XCTAssertNil(failedAgain?.diagnosis)
    }

    /// 换 agentId（重新配对）时清掉目录探测的诊断，存着的任务上也不能留。
    func testSetAgentIdClearsDirectoryDiagnosis() async {
        let calls = Counter()
        let store = store(probe: probe(.denied, calls: calls))
        await store.upsert(task(.running))
        await store.markBotBusTurn("claude:one", endsBefore: await store.turnEndCount("claude:one"))
        await store.upsert(task(.failed))
        await assertEventually { await store.task(id: "claude:one")?.diagnosis == .folderAccessDenied(.documents) }
        await store.setAgentId("other")
        let stored = await store.task(id: "claude:one")
        XCTAssertEqual(stored?.agentId, "other")
        XCTAssertNil(stored?.diagnosis)
    }

    /// 换 agentId 只清与配对有关的目录探测结果；连接器认出的原因（额度用完、没登录）是任务自己的事实，要留着，
    /// 否则一个不会再被 upsert 的失败任务重新配对后就没有提示了。
    func testSetAgentIdKeepsConnectorDiagnosis() async {
        let calls = Counter()
        let store = store(probe: probe(.denied, calls: calls))
        await store.upsert(task(.running, id: "claude:limit"))
        await store.upsert(task(.failed, diagnosis: .usageLimit(), id: "claude:limit"))
        await store.upsert(task(.running, id: "claude:dir"))
        await store.markBotBusTurn("claude:dir", endsBefore: await store.turnEndCount("claude:dir"))
        await store.upsert(task(.failed, id: "claude:dir"))
        await assertEventually { await store.task(id: "claude:dir")?.diagnosis == .folderAccessDenied(.documents) }
        await store.setAgentId("other")
        let limit = await store.task(id: "claude:limit")
        XCTAssertEqual(limit?.agentId, "other")
        XCTAssertEqual(limit?.diagnosis, .usageLimit())
        let dir = await store.task(id: "claude:dir")
        XCTAssertNil(dir?.diagnosis)
        // 之后的快照里也还带着，不只是内存里的记录。
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.first { $0.id == "claude:limit" }?.diagnosis, .usageLimit())
    }

    /// 只有 BotBus 起的那一轮失败才读目录；读到被拒就挂上，重新跑起来时撤掉。
    func testBotBusTurnFailureProbesDirectory() async {
        let calls = Counter()
        let store = store(probe: probe(.denied, calls: calls))
        await store.upsert(task(.running))
        await store.markBotBusTurn("claude:one", endsBefore: await store.turnEndCount("claude:one"))
        await store.upsert(task(.failed))
        await assertEventually { await store.task(id: "claude:one")?.diagnosis == .folderAccessDenied(.documents) }
        XCTAssertEqual(calls.value, 1)
        await store.upsert(task(.running))
        let retried = await store.task(id: "claude:one")
        XCTAssertNil(retried?.diagnosis)
    }

    func testDesktopTurnFailureDoesNotProbe() async {
        let calls = Counter()
        let store = store(probe: probe(.denied, calls: calls))
        await store.upsert(task(.running))
        await store.upsert(task(.failed))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.value, 0)
        let failed = await store.task(id: "claude:one")
        XCTAssertNil(failed?.diagnosis)
    }

    /// 连接器已经认出原因时不再读目录；一轮结束后标记作废，下一次桌面上的失败不探测。
    func testConnectorDiagnosisWinsAndTurnMarkIsConsumed() async {
        let calls = Counter()
        let store = store(probe: probe(.denied, calls: calls))
        await store.upsert(task(.running))
        await store.markBotBusTurn("claude:one", endsBefore: await store.turnEndCount("claude:one"))
        await store.upsert(task(.failed, diagnosis: .usageLimit()))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.value, 0)
        let failed = await store.task(id: "claude:one")
        XCTAssertEqual(failed?.diagnosis, .usageLimit())
        await store.upsert(task(.running))
        await store.upsert(task(.failed))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.value, 0)
    }

    /// 标记在任务仍停在上一轮的 failed 时打上：同样的 failed 刷新不算这一轮结束。
    func testMarkSurvivesRefreshOfPreviousFailure() async {
        let calls = Counter()
        let store = store(probe: probe(.missing, calls: calls))
        await store.upsert(task(.failed))
        await store.markBotBusTurn("claude:one", endsBefore: await store.turnEndCount("claude:one"))
        var refreshed = task(.failed)
        refreshed.lastMessage = "旧的失败"
        await store.upsert(refreshed)
        await store.upsert(task(.running))
        await store.upsert(task(.failed))
        await assertEventually { await store.task(id: "claude:one")?.diagnosis == .projectMissing }
    }

    /// 这一轮在分发器记下之前就失败了：记的时候立刻读目录，且不留标记——之后的失败（可能是终端里的）不探测。
    func testTurnThatEndedBeforeMarkingIsProbedAtOnce() async {
        let calls = Counter()
        let store = store(probe: probe(.missing, calls: calls))
        await store.upsert(task(.running))
        let before = await store.turnEndCount("claude:one")
        await store.upsert(task(.failed))
        let ended = await store.turnEndCount("claude:one")
        XCTAssertEqual(ended, before + 1)
        await store.markBotBusTurn("claude:one", endsBefore: before)
        await assertEventually { await store.task(id: "claude:one")?.diagnosis == .projectMissing }
        XCTAssertEqual(calls.value, 1)
        await store.upsert(task(.running))
        await store.upsert(task(.failed))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.value, 1)
        let later = await store.task(id: "claude:one")
        XCTAssertNil(later?.diagnosis)
    }

    /// 已经结束的一轮是成功的：不探测、也不留标记。
    func testTurnThatCompletedBeforeMarkingLeavesNoMark() async {
        let calls = Counter()
        let store = store(probe: probe(.missing, calls: calls))
        await store.upsert(task(.running))
        let before = await store.turnEndCount("claude:one")
        await store.upsert(task(.completed))
        await store.markBotBusTurn("claude:one", endsBefore: before)
        await store.upsert(task(.running))
        await store.upsert(task(.failed))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.value, 0)
    }

    /// 对账里消失的任务连同标记一起忘掉：同一个 id 再出现、再失败也不探测。
    func testReconcileRemovalDropsTheMark() async {
        let calls = Counter()
        let store = store(probe: probe(.missing, calls: calls))
        await store.reconcile(source: .claude, tasks: [task(.running)], projects: [])
        await store.markBotBusTurn("claude:one", endsBefore: await store.turnEndCount("claude:one"))
        await store.reconcile(source: .claude, tasks: [], projects: [])
        let removed = await store.task(id: "claude:one")
        XCTAssertNil(removed)
        await store.reconcile(source: .claude, tasks: [task(.running)], projects: [])
        await store.reconcile(source: .claude, tasks: [task(.failed)], projects: [])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.value, 0)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
