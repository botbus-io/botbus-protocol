import Foundation
import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

/// `AcpConnector` 当一档来源用（协议 3.1 的 DeepSeek Harness）：`.builtin` 身份、`session/resume`、会话锁错误。
final class AcpConnectorBuiltinTests: XCTestCase {
    private let project = FileManager.default.temporaryDirectory.path
    private static let resumeOnly: JSONValue = [
        "loadSession": false, "promptCapabilities": ["image": false],
        "sessionCapabilities": ["list": [:], "resume": [:], "close": [:]],
    ]

    private func dshRecord(_ sessionId: String, cwd: String) -> TaskRecord {
        var record = AcpSessionState.newRecord(identity: .builtin(.dsh), sessionId: sessionId, cwd: cwd, title: "旧会话",
                                               origin: .desktop, controllable: true, at: "2026-09-26T08:00:00Z")
        record.status = .completed
        return record
    }

    func testCapabilitiesParseResume() {
        let caps = AcpCapabilities(initializeResult: ["protocolVersion": 1, "agentCapabilities": Self.resumeOnly])
        XCTAssertTrue(caps.resumeSession)
        XCTAssertFalse(caps.loadSession)
        XCTAssertTrue(caps.canContinueSessions)
        let none = AcpCapabilities(initializeResult: ["protocolVersion": 1, "agentCapabilities": ["loadSession": false]])
        XCTAssertFalse(none.resumeSession)
        XCTAssertFalse(none.canContinueSessions)
    }

    func testIdentityRoundTrip() {
        let dsh = AcpTaskIdentity.builtin(.dsh)
        XCTAssertEqual(dsh.taskId(sessionId: "session-abc"), "dsh:session-abc")
        XCTAssertEqual(dsh.sessionId(taskId: "dsh:session-abc"), "session-abc")
        XCTAssertNil(dsh.sessionId(taskId: "dsh:"))
        XCTAssertNil(dsh.sessionId(taskId: "acp:dsh:x"))
        XCTAssertEqual(dsh.source, .dsh)
        XCTAssertNil(dsh.connectorId)
        let acp = AcpTaskIdentity.acp(connectorId: "my-agent")
        XCTAssertEqual(acp.taskId(sessionId: "s"), "acp:my-agent:s")
        XCTAssertEqual(acp.sessionId(taskId: "acp:my-agent:s"), "s")
        XCTAssertNil(acp.sessionId(taskId: "acp:other:s"))
        XCTAssertNil(acp.sessionId(taskId: "dsh:s"))
    }

    func testBuiltinIdentityProducesDshTasks() async throws {
        let h = await AcpHarness.make(identity: .builtin(.dsh))
        let outcome = try await h.connector.start(projectPath: project, prompt: "你好", images: [])
        XCTAssertEqual(outcome.taskId, "dsh:sess-1")
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        let record = await h.task(outcome.taskId)
        XCTAssertEqual(record?.source, .dsh)
        XCTAssertNil(record?.connectorId)
        XCTAssertEqual(record?.lastMessage, "好的")
        XCTAssertEqual(record?.origin, .watch)

        let listed = await h.connector.staticTasks()
        XCTAssertEqual(listed.map(\.id), ["dsh:sess-1"])
        XCTAssertEqual(listed.first?.source, .dsh)

        // 同一进程里续聊直接 prompt；ACP 形状的 id 不认。
        _ = try await h.connector.followUp(taskId: outcome.taskId, prompt: "再来", images: [])
        await assertEventually { h.behavior.methods().filter { $0 == "session/prompt" }.count == 2 }
        do {
            _ = try await h.connector.followUp(taskId: "acp:my-agent:sess-1", prompt: "x", images: [])
            XCTFail("应当拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不属于这个 agent"), error.localizedDescription)
        }
    }

    func testCompleteTranscriptOnlyForSessionsWeHaveInFull() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        let h = await AcpHarness.make(behavior: behavior, identity: .builtin(.dsh))
        let outcome = try await h.connector.start(projectPath: project, prompt: "第一句", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        let complete = await h.connector.completeTranscript(taskId: outcome.taskId, limit: 40)
        XCTAssertEqual(complete?.entries.map(\.message.text), ["第一句", "好的"])
        let inProcess = await h.connector.isInProcess(taskId: outcome.taskId)
        XCTAssertTrue(inProcess)
        let unknown = await h.connector.completeTranscript(taskId: "dsh:nope", limit: 40)
        XCTAssertNil(unknown)
    }

    /// 只有 resume 的 agent：不在进程里的会话先 `session/resume`（cwd 取记录里的、注入 botbus MCP）再 prompt，不期待重放。
    func testFollowUpResumesWhenAgentOnlyHasResume() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        let tools = AgentToolsConfiguration(cliPath: "/bin/sh", toolsURL: "http://127.0.0.1:1")
        let h = await AcpHarness.make(behavior: behavior, tools: tools, identity: .builtin(.dsh))
        await h.store.upsert(dshRecord("session-old", cwd: project))
        let outcome = try await h.connector.followUp(taskId: "dsh:session-old", prompt: "继续", images: [])
        XCTAssertEqual(outcome.taskId, "dsh:session-old")
        XCTAssertTrue(outcome.retainsLiveOwnership)
        await assertEventually { await h.task("dsh:session-old")?.status == .completed }
        XCTAssertEqual(h.behavior.methods(), ["initialize", "session/resume", "session/prompt"])
        let params = h.behavior.params.withLock { $0["session/resume"] }
        XCTAssertEqual(params?["sessionId"], "session-old")
        XCTAssertEqual(params?["cwd"]?.stringValue, project)
        XCTAssertEqual(params?["mcpServers"]?[0]?["name"], "botbus")
        let record = await h.task("dsh:session-old")
        XCTAssertEqual(record?.lastMessage, "好的")
        XCTAssertEqual(record?.source, .dsh)
        XCTAssertEqual(record?.origin, .desktop, "接上的是电脑上的会话，来源不改")

        // resume 不重放：内存里只有接上之后的一轮，不算齐全。
        let complete = await h.connector.completeTranscript(taskId: "dsh:session-old", limit: 40)
        XCTAssertNil(complete)
        let (entries, _) = try await h.connector.entries(taskId: "dsh:session-old", limit: 40)
        XCTAssertEqual(entries.map(\.message.text), ["继续", "好的"])

        // 再续聊不再 resume。
        _ = try await h.connector.followUp(taskId: "dsh:session-old", prompt: "还有", images: [])
        await assertEventually { h.behavior.methods().filter { $0 == "session/prompt" }.count == 2 }
        XCTAssertEqual(h.behavior.methods().filter { $0 == "session/resume" }.count, 1)
    }

    /// 只有 resume、没有 load 的 agent 上没载入过的会话照样能续聊。
    func testResumeOnlyAgentMarksListedSessionsControllable() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        behavior.listed = [["sessionId": "session-x", "cwd": .string(project)]]
        let h = await AcpHarness.make(behavior: behavior, identity: .builtin(.dsh))
        await h.connector.refreshList()
        let listed = await h.connector.staticTasks()
        XCTAssertEqual(listed.map(\.id), ["dsh:session-x"])
        XCTAssertEqual(listed.first?.controllable, true)
    }

    /// dsh 的会话锁：-32603 + `data.details` 里的 "already owned by an active write handle" → `sessionBusyElsewhere`。
    func testResumeLockErrorIsDistinguishable() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        behavior.resumeError = JSONRPCError(code: -32603, message: "Internal error", data: [
            "details": "session session-old is already owned by an active write handle",
        ])
        let h = await AcpHarness.make(behavior: behavior, identity: .builtin(.dsh))
        await h.store.upsert(dshRecord("session-old", cwd: project))
        do {
            _ = try await h.connector.followUp(taskId: "dsh:session-old", prompt: "继续", images: [])
            XCTFail("应当失败")
        } catch let error as AcpConnectorError {
            XCTAssertEqual(error.reason, .sessionBusyElsewhere)
            XCTAssertTrue(error.localizedDescription.contains("正开在电脑上"), error.localizedDescription)
        }
        XCTAssertFalse(h.behavior.methods().contains("session/prompt"))
        let record = await h.task("dsh:session-old")
        XCTAssertEqual(record?.status, .completed, "没发出去的续聊不改任务状态")
        let inProcess = await h.connector.isInProcess(taskId: "dsh:session-old")
        XCTAssertFalse(inProcess)

        // 锁放掉之后能再试（占位已清）。
        behavior.resumeError = nil
        _ = try await h.connector.followUp(taskId: "dsh:session-old", prompt: "继续", images: [])
        await assertEventually { await h.task("dsh:session-old")?.status == .completed }
    }

    /// 其他 -32603 照旧是普通错误。
    func testOtherInternalErrorsStayGeneric() {
        XCTAssertFalse(AcpConnectorError.isSessionLockError(JSONRPCError(code: -32603, message: "turn failed: boom")))
        XCTAssertFalse(AcpConnectorError.isSessionLockError(JSONRPCError(
            code: -32000, message: "x", data: ["details": "already owned by an active write handle"])))
        XCTAssertTrue(AcpConnectorError.isSessionLockError(JSONRPCError(
            code: -32603, message: "x", data: ["details": "… is already owned by an active write handle"])))
    }

    /// 读记录从不 resume：内存里没有、agent 又不能 load 时抛 `transcriptUnavailable`，交给外层读盘。
    func testEntriesWithoutLoadSessionAreLeftToTheOwner() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        let h = await AcpHarness.make(behavior: behavior, identity: .builtin(.dsh))
        await h.store.upsert(dshRecord("session-old", cwd: project))
        do {
            _ = try await h.connector.entries(taskId: "dsh:session-old", limit: 40)
            XCTFail("应当失败")
        } catch let error as AcpConnectorError {
            XCTAssertEqual(error.reason, .transcriptUnavailable)
        }
        XCTAssertFalse(h.behavior.methods().contains("session/resume"))
        XCTAssertFalse(h.behavior.methods().contains("session/load"))
    }

    /// 第三方 agent 没有 resume 也没有 load 时，读记录同样给出可识别的错误。
    func testAcpEntriesWithoutLoadSessionThrowTranscriptUnavailable() async throws {
        let h = await AcpHarness.make()
        await h.store.upsert(acpRecord("my-agent", "old", cwd: project))
        do {
            _ = try await h.connector.entries(taskId: "acp:my-agent:old", limit: 40)
            XCTFail("应当失败")
        } catch let error as AcpConnectorError {
            XCTAssertEqual(error.reason, .transcriptUnavailable)
        }
    }
}
