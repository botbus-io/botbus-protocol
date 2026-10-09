import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit

final class ObservedTaskNotificationsTests: XCTestCase {
    private let agentID = "agent-recurring-00000"

    private func store() -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: agentID, name: "电脑", appVersion: "1"),
                  now: { Date(timeIntervalSince1970: 1_791_500_000) })
    }

    private func task(_ run: Int, _ status: TaskStatus = .failed, source: TaskSource = .hermes,
                      id: String? = nil) -> TaskRecord {
        let date = ProtocolJSON.timestamp(Date(timeIntervalSince1970: 1_791_400_000 + Double(run * 600)))
        return TaskRecord(id: id ?? "\(source.rawValue):run-\(run)", agentId: agentID, source: source,
                          title: "Scheduled research", projectPath: "/p", projectName: "p", status: status,
                          lastMessage: "Your request was not processed.", origin: .desktop, controllable: true,
                          startedAt: date, updatedAt: date)
    }

    private func context(_ fingerprint: String? = "connection", group: String = "cron-job",
                         body: String? = nil) -> ObservedTaskNotification {
        ObservedTaskNotification(groupID: group, failureFingerprint: fingerprint, failureBody: body)
    }

    private func reconcile(_ store: TaskStore, _ task: TaskRecord,
                           context: ObservedTaskNotification? = nil) async -> [Event] {
        await store.reconcile(source: task.source, tasks: [task], projects: [],
                              notifications: [task.id: context ?? self.context()])
    }

    private func notifications(_ events: [Event]) -> [Notify] { events.compactMap(\.notify) }

    func testFirstFailureNotifiesAndNextRunSameFailureOnlyUpdatesTasks() async {
        let store = store()
        await store.reconcile(source: .hermes, tasks: [], projects: [])
        let first = task(1)
        let second = task(2)
        let firstEvents = await reconcile(store, first)
        XCTAssertEqual(notifications(firstEvents).map(\.taskId), [first.id])
        let events = await store.reconcile(source: .hermes, tasks: [second, first], projects: [],
                                          notifications: [first.id: context(), second.id: context()])
        XCTAssertTrue(notifications(events).isEmpty)
        XCTAssertEqual(events.compactMap(\.task).map(\.id), [second.id])
        let snapshot = await store.snapshot()
        XCTAssertEqual(Set(snapshot.tasks.map(\.id)), Set([first.id, second.id]))
        XCTAssertTrue(snapshot.tasks.allSatisfy { $0.status == .failed })
    }

    func testDifferentErrorNotifiesIncludingMetadataOnlyChangeOfSameRun() async {
        let store = store()
        await store.reconcile(source: .hermes, tasks: [], projects: [])
        _ = await reconcile(store, task(1))
        let second = task(2)
        let changed = await reconcile(store, second, context: context("quota"))
        XCTAssertEqual(notifications(changed).map(\.taskId), [second.id])
        let metadataOnly = await reconcile(store, second, context: context("authentication", body: "Real error"))
        XCTAssertEqual(notifications(metadataOnly).map(\.body), ["Real error"])
        XCTAssertTrue(metadataOnly.compactMap(\.task).isEmpty)
        let unchanged = await reconcile(store, second, context: context("authentication", body: "Reworded error"))
        XCTAssertTrue(notifications(unchanged).isEmpty)
    }

    func testSuccessThenFailureNotifiesAgainAndSameRunCanRecover() async {
        let store = store()
        await store.reconcile(source: .hermes, tasks: [], projects: [])
        _ = await reconcile(store, task(1))
        let success = await reconcile(store, task(2, .completed))
        XCTAssertEqual(notifications(success).map(\.category), [.taskDone])
        let failure = await reconcile(store, task(3))
        XCTAssertEqual(notifications(failure).map(\.category), [.taskFailed])
        let corrected = await reconcile(store, task(3, .completed))
        XCTAssertEqual(notifications(corrected).map(\.category), [.taskDone])
    }

    func testDifferentGroupsAndSourcesHaveIndependentFailureMemory() async {
        let store = store()
        await store.reconcile(source: .hermes, tasks: [], projects: [])
        await store.reconcile(source: .pi, tasks: [], projects: [])
        _ = await reconcile(store, task(1))
        let differentGroup = await reconcile(store, task(2), context: context(group: "other-job"))
        XCTAssertEqual(notifications(differentGroup).count, 1)
        let differentSource = await reconcile(store, task(3, source: .pi))
        XCTAssertEqual(notifications(differentSource).count, 1)
    }

    func testBatchOrderOnlyNotifiesNewestTerminalAndOldHistoryCannotRollback() async {
        for reversed in [false, true] {
            let store = store()
            await store.reconcile(source: .hermes, tasks: [], projects: [])
            let history = [task(1), task(2, .completed), task(3)]
            let events = await store.reconcile(source: .hermes, tasks: reversed ? history.reversed() : history,
                                              projects: [], notifications: Dictionary(
                                                uniqueKeysWithValues: history.map { ($0.id, context()) }))
            XCTAssertEqual(notifications(events).map(\.taskId), [history[2].id])
            let olderSuccess = await reconcile(store, history[1])
            XCTAssertTrue(notifications(olderSuccess).isEmpty)
            let olderChangedFailure = await reconcile(store, history[0], context: context("different-old-error"))
            XCTAssertTrue(notifications(olderChangedFailure).isEmpty)
            let repeated = await reconcile(store, task(4))
            XCTAssertTrue(notifications(repeated).isEmpty)
        }
    }

    func testRunningInterruptedAndIdleDoNotResetFailureMemory() async {
        let store = store()
        await store.reconcile(source: .hermes, tasks: [], projects: [])
        _ = await reconcile(store, task(1))
        for status in [TaskStatus.running, .interrupted, .idle] {
            _ = await reconcile(store, task(2, status))
        }
        let repeated = await reconcile(store, task(3))
        XCTAssertTrue(notifications(repeated).isEmpty)
    }

    func testOfflineHistoryRemembersIntermediateRecoveryAndOnlyNotifiesLatest() async {
        let store = store()
        _ = await reconcile(store, task(1))
        let history = [task(4), task(2, .completed), task(3), task(1)]
        let events = await store.reconcile(source: .hermes, tasks: history, projects: [],
                                          notifications: Dictionary(uniqueKeysWithValues: history.map { ($0.id, context()) }))
        XCTAssertEqual(notifications(events).map(\.taskId), [task(4).id])
        let repeatEvents = await store.reconcile(source: .hermes, tasks: history, projects: [],
                                                notifications: Dictionary(uniqueKeysWithValues: history.map { ($0.id, context()) }))
        XCTAssertTrue(notifications(repeatEvents).isEmpty)
    }

    func testBatchOfSameFailuresNotifiesOnlyOnceForFirstOrChangedFailure() async {
        for previousFingerprint in [nil, "connection", "quota"] as [String?] {
            let store = store()
            if let previousFingerprint {
                _ = await reconcile(store, task(1), context: context(previousFingerprint))
            } else { await store.reconcile(source: .hermes, tasks: [], projects: []) }
            let failures = [task(3), task(2)]
            let events = await store.reconcile(source: .hermes, tasks: failures, projects: [],
                                              notifications: Dictionary(uniqueKeysWithValues: failures.map { ($0.id, context()) }))
            let expected = previousFingerprint == "connection" ? [] : [task(3).id]
            XCTAssertEqual(notifications(events).map(\.taskId), expected)
        }
    }

    func testOlderMetadataRevisionOfSameRunCannotChangeFailureMemory() async {
        let store = store()
        _ = await reconcile(store, task(1))
        var older = task(1)
        older.updatedAt = task(0).updatedAt
        let events = await reconcile(store, older, context: context("stale-other-error"))
        XCTAssertTrue(notifications(events).isEmpty)
        let next = await reconcile(store, task(2))
        XCTAssertTrue(notifications(next).isEmpty)
    }

    func testBaselineSeedsLatestGroupSilentlyAndReenableSeedsFreshBaseline() async {
        let store = store()
        let baseline = await reconcile(store, task(1))
        XCTAssertTrue(notifications(baseline).isEmpty)
        let repeated = await reconcile(store, task(2))
        XCTAssertTrue(notifications(repeated).isEmpty)
        await store.setConnectorEnabled(.hermes, enabled: false)
        await store.setConnectorEnabled(.hermes, enabled: true)
        let reenabled = await reconcile(store, task(3), context: context("quota"))
        XCTAssertTrue(notifications(reenabled).isEmpty)
        let stillFailed = await reconcile(store, task(4), context: context("quota"))
        XCTAssertTrue(notifications(stillFailed).isEmpty)
        let changedError = await reconcile(store, task(5))
        XCTAssertEqual(notifications(changedError).count, 1)
    }

    func testIdentityChangeSeedsNewNotificationBaseline() async {
        let store = store()
        _ = await reconcile(store, task(1))
        await store.setAgentId("agent-new-0000000000")
        let rebaseline = await reconcile(store, task(2), context: context("quota"))
        XCTAssertTrue(notifications(rebaseline).isEmpty)
        let different = await reconcile(store, task(3))
        XCTAssertEqual(notifications(different).count, 1)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.first?.agentId, "agent-new-0000000000")
    }

    func testRemovedOrMissingSessionDoesNotForgetGroupFailure() async {
        let store = store()
        await store.reconcile(source: .hermes, tasks: [], projects: [])
        let first = task(1)
        _ = await reconcile(store, first)
        await store.remove(id: first.id)
        await store.reconcile(source: .hermes, tasks: [], projects: [])
        let second = await reconcile(store, task(2))
        XCTAssertTrue(notifications(second).isEmpty)
        await store.reconcile(source: .hermes, tasks: [], projects: [])
        let restored = await reconcile(store, first, context: context("old-different-error"))
        XCTAssertTrue(notifications(restored).isEmpty)
    }

    func testLiveHiddenAndInvalidIDCannotChangeFailureMemory() async {
        for exclusion in ["live", "hidden", "invalid"] {
            let store = store()
            await store.reconcile(source: .hermes, tasks: [], projects: [])
            _ = await reconcile(store, task(1))
            let success = task(2, .completed, id: exclusion == "invalid" ? "pi:wrong-source" : nil)
            if exclusion == "live" { await store.claimLive(success.id) }
            if exclusion == "hidden" { await store.hide(id: success.id) }
            _ = await reconcile(store, success)
            let repeated = await reconcile(store, task(3))
            XCTAssertTrue(notifications(repeated).isEmpty, exclusion)
        }
    }

    func testDismissedProjectCannotAdvanceGroupMemoryUntilNewActivityRestoresIt() async throws {
        let store = store()
        let first = task(1)
        _ = await reconcile(store, first)
        try await store.removeProject(path: "/p")
        // 早于项目删除切线的历史成功，不能恢复项目或清掉故障记忆。
        let historical = task(0, .completed)
        _ = await reconcile(store, historical)
        let newerFailure = await reconcile(store, task(2))
        XCTAssertTrue(notifications(newerFailure).isEmpty)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.map(\.id), [task(2).id])
    }

    func testFailureBodyDoesNotReplaceTaskLastMessageAndIsBounded() async {
        let store = store()
        await store.reconcile(source: .hermes, tasks: [], projects: [])
        let first = task(1)
        let body = "Scheduled research: " + String(repeating: "x", count: 700)
        let events = await reconcile(store, first, context: context(body: body))
        XCTAssertEqual(notifications(events).first?.body, String(body.prefix(SessionFormatting.lastMessageLimit)))
        let stored = await store.task(id: first.id)
        XCTAssertEqual(stored?.lastMessage, first.lastMessage)
    }

    func testUnknownFailureFingerprintDoesNotMergeUnrelatedErrors() async {
        let store = store()
        await store.reconcile(source: .hermes, tasks: [], projects: [])
        _ = await reconcile(store, task(1), context: context(nil))
        let next = await reconcile(store, task(2), context: context(nil))
        XCTAssertEqual(notifications(next).count, 1)
    }

    func testUncontextualizedTasksRetainNormalNotificationBehavior() async {
        let store = store()
        await store.reconcile(source: .hermes, tasks: [], projects: [])
        let first = await store.reconcile(source: .hermes, tasks: [task(1)], projects: [])
        let second = await store.reconcile(source: .hermes, tasks: [task(2)], projects: [])
        XCTAssertEqual(notifications(first).count, 1)
        XCTAssertEqual(notifications(second).count, 1)
    }

    func testGroupMemoryIsBoundedAndKeepsNewestRuns() {
        var policy = ObservedTaskNotifications()
        let history = (0...ObservedTaskNotifications.maxGroups).map { task($0) }
        let contexts = Dictionary(uniqueKeysWithValues: history.map { ($0.id, context(group: $0.id)) })
        _ = policy.decisions(source: .hermes, tasks: history, notifications: contexts, silent: true)
        XCTAssertEqual(policy.groupCount, ObservedTaskNotifications.maxGroups)
        let newest = history.last!
        let decision = policy.decisions(source: .hermes, tasks: [newest], notifications: contexts, silent: false)
        XCTAssertEqual(decision[newest.id]?.notify, false)
        policy.reset(source: .hermes)
        XCTAssertEqual(policy.groupCount, 0)
    }

    func testEvictedGroupUnchangedHistoryDoesNotNotifyOnEveryPoll() async {
        let store = store()
        let history = (0...ObservedTaskNotifications.maxGroups).map { task($0) }
        let contexts = Dictionary(uniqueKeysWithValues: history.map { ($0.id, context(group: $0.id)) })
        await store.reconcile(source: .hermes, tasks: history, projects: [], notifications: contexts)
        for _ in 0..<3 {
            let events = await store.reconcile(source: .hermes, tasks: history.reversed(), projects: [], notifications: contexts)
            XCTAssertTrue(notifications(events).isEmpty)
        }
    }

    func testLegacySnapshotSourceDefaultAndObserverRichSnapshotForwarding() async throws {
        struct LegacySource: SessionSnapshotSource {
            let task: TaskRecord
            func readSnapshot(agentId: String) throws -> (tasks: [TaskRecord], projects: [Project]) { ([task], []) }
        }
        struct RichSource: SessionSnapshotSource {
            let snapshot: ObservedSessionSnapshot
            func readSnapshot(agentId: String) throws -> (tasks: [TaskRecord], projects: [Project]) { ([], []) }
            func readObservedSnapshot(agentId: String) throws -> ObservedSessionSnapshot { snapshot }
        }
        let legacy = try LegacySource(task: task(1)).readObservedSnapshot(agentId: agentID)
        XCTAssertEqual(legacy.tasks.count, 1)
        XCTAssertTrue(legacy.notifications.isEmpty)
        let store = store()
        let first = task(1)
        let second = task(2)
        let pending = Locked([
            ObservedSessionSnapshot(tasks: [first], projects: [], notifications: [first.id: context()]),
            ObservedSessionSnapshot(tasks: [second], projects: [], notifications: [second.id: context()])
        ])
        let observer = SessionObserver(source: .hermes, store: store, provider: {
            RichSource(snapshot: pending.withLock { $0.removeFirst() })
        })
        await observer.pollOnce()
        await observer.pollOnce()
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.map(\.id), [second.id])
        let next = await reconcile(store, task(3))
        XCTAssertTrue(notifications(next).isEmpty, "观察者必须把分组上下文传到store")
    }
}
