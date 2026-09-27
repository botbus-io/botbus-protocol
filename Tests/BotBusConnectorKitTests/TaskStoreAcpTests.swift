import Foundation
import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit

final class TaskStoreAcpTests: XCTestCase {
    func testAcpTaskVisibleOnlyWhileItsAgentIsEnabled() async {
        let store = makeAcpStore(["gemini", "goose"])
        await store.upsert(acpRecord("gemini", "s1"))
        await store.upsert(acpRecord("goose", "s2"))
        await store.upsert(acpRecord("unknown", "s3"))
        var ids = await store.snapshot().tasks.map(\.id).sorted()
        XCTAssertEqual(ids, ["acp:gemini:s1", "acp:goose:s2"], "没发现到的 agent 的任务不收")

        let events = await store.setAcpConnectorEnabled("goose", enabled: false)
        XCTAssertTrue(events.contains(.taskRemoved("acp:goose:s2")))
        XCTAssertEqual(events.last?.kind, .snapshot)
        ids = await store.snapshot().tasks.map(\.id)
        XCTAssertEqual(ids, ["acp:gemini:s1"])
    }

    func testSnapshotReportsAcpConnectorsWithCounts() async {
        let store = makeAcpStore(["gemini"])
        await store.upsert(acpRecord("gemini", "s1"))
        await store.upsert(acpRecord("gemini", "s2"))
        let info = await store.snapshot().agents.first?.connectors.first { $0.connectorId == "gemini" }
        XCTAssertEqual(info?.taskCount, 2)
        XCTAssertEqual(info?.kind, .acp)
    }

    func testReconcileDropsDisabledAgentsTasks() async {
        let store = makeAcpStore(["gemini", "goose"])
        store.connectors.setAcpEnabled(false, for: "goose")
        await store.reconcile(source: .acp, tasks: [acpRecord("gemini", "s1"), acpRecord("goose", "s2")], projects: [])
        let ids = await store.snapshot().tasks.map(\.id)
        XCTAssertEqual(ids, ["acp:gemini:s1"])
    }

    func testSetConnectorEnabledCommandForAcp() async {
        let store = makeAcpStore(["gemini"])
        let command = Command.setConnectorEnabled(.init(connector: .acp, enabled: false, connectorId: "gemini"),
                                                  createdAt: "2026-09-26T08:00:00Z", id: "c1", agentId: "agent-1")
        let (result, _) = await store.handle(command)
        XCTAssertTrue(result.ok)
        XCTAssertFalse(store.connectors.isAcpEnabled("gemini"))

        let unknown = Command.setConnectorEnabled(.init(connector: .acp, enabled: false, connectorId: "nope"),
                                                  createdAt: "2026-09-26T08:00:00Z", id: "c2", agentId: "agent-1")
        let (failed, _) = await store.handle(unknown)
        XCTAssertFalse(failed.ok)
    }

    // MARK: - 按 agent 的静默基线

    /// (a) 关了又开，拿"老任务"重新对账不能把积压状态当成变化推通知；
    /// (b) 基线建立之后，真实的状态变化要能正常提醒。
    func testReenablingAcpAgentResyncsSilently() async {
        let store = makeAcpStore(["gemini"])
        _ = await store.reconcileAcp(tasks: [acpRecord("gemini", "s1", status: .running)], projects: [],
                                     baselined: ["gemini"])
        _ = await store.setAcpConnectorEnabled("gemini", enabled: false)
        _ = await store.setAcpConnectorEnabled("gemini", enabled: true)

        // (a) 重新启用后第一次全量对账仍是静默基线，即使这条"老任务"本该触发 .done 通知。
        let oldTask = acpRecord("gemini", "s1", status: .completed, updatedAt: "2026-09-26T09:00:00Z")
        let events = await store.reconcileAcp(tasks: [oldTask], projects: [], baselined: ["gemini"])
        XCTAssertEqual(events.map(\.kind), [.taskUpdated], "重新启用后的首次全量对账仍是静默基线")

        // (b) 基线建立之后，同一个 agent 再来一次真实的状态变化要能正常提醒。
        let changed = acpRecord("gemini", "s1", status: .failed, updatedAt: "2026-09-26T09:01:00Z")
        let notified = await store.reconcileAcp(tasks: [changed], projects: [], baselined: ["gemini"])
        XCTAssertEqual(notified.map(\.kind), [.taskUpdated, .notify], "基线建立之后的真实变化要正常提醒")
        XCTAssertEqual(notified.last?.notify?.category, .taskFailed)
    }

    /// (c) `.acp` 整体早已同步过之后才被发现的新 agent，它的第一批任务同样是静默基线。
    func testNewlyDiscoveredAcpAgentBaselineIsSilent() async {
        let store = makeAcpStore(["gemini"])
        _ = await store.reconcileAcp(tasks: [acpRecord("gemini", "s1", status: .running)], projects: [],
                                     baselined: ["gemini"])

        // goose 是这之后才被 AcpHub 探测到的，此时 `.acp` 这个来源早已建立过基线。
        store.connectors.setAcpEntries([
            ConnectorRegistry.AcpEntry(id: "gemini", displayName: "Gemini", defaultEnabled: true,
                                       canStartTask: true, status: .ok, lastError: nil),
            ConnectorRegistry.AcpEntry(id: "goose", displayName: "Goose", defaultEnabled: true,
                                       canStartTask: true, status: .ok, lastError: nil)
        ])

        var goose = acpRecord("goose", "s2", status: .waitingApproval)
        goose.pendingRequest = PendingRequest(id: "req-1", kind: .command, summary: "新 agent 的第一条任务")
        let events = await store.reconcileAcp(tasks: [acpRecord("gemini", "s1", status: .running), goose],
                                              projects: [], baselined: ["gemini", "goose"])
        XCTAssertEqual(events.map(\.kind), [.taskUpdated], "刚发现的 agent 第一次对账不该推通知，即使它带着待审批")

        let ids = await store.snapshot().tasks.map(\.id).sorted()
        XCTAssertEqual(ids, ["acp:gemini:s1", "acp:goose:s2"])
    }

    /// 重启：本机记录先到（列表基线还没就绪），第一次列表拉回来的已完成桌面会话不推通知。
    func testArchiveThenFirstListDoesNotNotify() async {
        let store = makeAcpStore(["gemini"])
        let first = await store.reconcileAcp(tasks: [acpRecord("gemini", "archived", status: .completed)],
                                             projects: [], baselined: [])
        XCTAssertFalse(first.contains { $0.kind == .notify })
        let second = await store.reconcileAcp(tasks: [acpRecord("gemini", "archived", status: .completed),
                                                      acpRecord("gemini", "desk1", status: .completed),
                                                      acpRecord("gemini", "desk2", status: .completed)],
                                              projects: [], baselined: ["gemini"])
        XCTAssertFalse(second.contains { $0.kind == .notify }, "列表基线刚就绪的这一轮是静默的")
        // 就绪之后，列表里新出现的已完成会话照常提醒。
        let third = await store.reconcileAcp(tasks: [acpRecord("gemini", "archived", status: .completed),
                                                     acpRecord("gemini", "desk1", status: .completed),
                                                     acpRecord("gemini", "desk2", status: .completed),
                                                     acpRecord("gemini", "desk3", status: .completed)],
                                             projects: [], baselined: ["gemini"])
        XCTAssertEqual(third.compactMap(\.notify).map(\.taskId), ["acp:gemini:desk3"])
    }

    /// agent 从注册表条目里消失再回来：它的基线跟着作废，回来后重新静默一轮。
    func testVanishedAndReturnedAgentResyncsSilently() async {
        let store = makeAcpStore(["gemini"])
        _ = await store.reconcileAcp(tasks: [acpRecord("gemini", "s1", status: .completed)], projects: [],
                                     baselined: ["gemini"])
        store.connectors.setAcpEntries([])
        // 没发现到的 agent：即使调用方还把它报成就绪，也不能留在基线里。
        _ = await store.reconcileAcp(tasks: [], projects: [], baselined: ["gemini"])
        store.connectors.setAcpEntries([ConnectorRegistry.AcpEntry(id: "gemini", displayName: "Gemini",
                                                                   defaultEnabled: true, canStartTask: true,
                                                                   status: .ok, lastError: nil)])
        let back = await store.reconcileAcp(tasks: [acpRecord("gemini", "s1", status: .completed)], projects: [],
                                            baselined: ["gemini"])
        XCTAssertFalse(back.contains { $0.kind == .notify }, "回来的 agent 第一次对账静默")
    }

    /// 基线就绪之前的对账全静默，但实时写入（BotBus 自己跑的一轮、反向连接报的会话）照常提醒。
    func testLiveUpsertStillNotifiesRegardlessOfBaseline() async {
        let store = makeAcpStore(["gemini"])
        _ = await store.reconcileAcp(tasks: [acpRecord("gemini", "s1", status: .running)], projects: [], baselined: [])
        var waiting = acpRecord("gemini", "s1", status: .waitingApproval)
        waiting.pendingRequest = PendingRequest(id: "req-1", kind: .command, summary: "跑测试")
        let approval = await store.upsert(waiting)
        XCTAssertEqual(approval.compactMap(\.notify).map(\.category), [.taskApproval])
        let done = await store.upsert(acpRecord("gemini", "s1", status: .completed))
        XCTAssertEqual(done.compactMap(\.notify).map(\.category), [.taskDone])
    }

    /// 只经 `reconcile(source: .acp, …)` 进来（没报基线）的对账一律静默。
    func testPlainAcpReconcileNeverNotifies() async {
        let store = makeAcpStore(["gemini"])
        _ = await store.reconcile(source: .acp, tasks: [acpRecord("gemini", "s1", status: .running)], projects: [])
        let events = await store.reconcile(source: .acp, tasks: [acpRecord("gemini", "s1", status: .failed)], projects: [])
        XCTAssertFalse(events.contains { $0.kind == .notify })
    }

    /// 推送标题用注册表里的显示名，不用 connectorId。
    func testAcpNotificationTitleUsesDisplayName() async {
        let store = makeAcpStore(["my-agent"])
        let events = await store.upsert(acpRecord("my-agent", "s1", status: .completed))
        XCTAssertEqual(events.compactMap(\.notify).map(\.title), ["My Agent 任务完成"])
    }
}
