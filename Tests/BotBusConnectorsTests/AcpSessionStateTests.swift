import Foundation
import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class AcpSessionStateTests: XCTestCase {
    private let t0 = "2026-09-26T08:00:00Z"
    private let t1 = "2026-09-26T08:01:00Z"

    private func fresh() -> AcpSessionState {
        AcpSessionState(record: AcpSessionState.newRecord(connectorId: "my-agent", sessionId: "s1",
                                                          cwd: "/Users/me/app", title: nil, origin: .watch,
                                                          controllable: true, at: t0))
    }

    func testNewRecordShape() {
        let record = fresh().record
        XCTAssertEqual(record.id, "acp:my-agent:s1")
        XCTAssertEqual(record.source, .acp)
        XCTAssertEqual(record.connectorId, "my-agent")
        XCTAssertEqual(record.title, "app", "没有标题时先用项目名")
        XCTAssertEqual(record.status, .idle)
    }

    func testTurnCompletesWithAgentText() {
        var state = fresh()
        state.beginTurn(prompt: "修一下登录", images: [], at: t0)
        XCTAssertEqual(state.record.status, .running)
        XCTAssertEqual(state.record.title, "修一下登录", "首条 prompt 当标题")
        state.apply(.agentMessage(text: "好的，", images: []), at: t0)
        state.apply(.agentMessage(text: "已经修好", images: []), at: t0)
        state.endTurn(.endTurn, error: nil, at: t1)
        XCTAssertEqual(state.record.status, .completed)
        XCTAssertEqual(state.record.lastMessage, "好的，已经修好")
        XCTAssertEqual(state.record.updatedAt, t1)
    }

    func testStopReasonMapping() {
        let cases: [(AcpStopReason, TaskStatus)] = [
            (.endTurn, .completed), (.cancelled, .interrupted),
            (.refusal, .failed), (.maxTokens, .failed), (.maxTurnRequests, .failed),
        ]
        for (reason, status) in cases {
            var state = fresh()
            state.beginTurn(prompt: "x", images: [], at: t0)
            state.endTurn(reason, error: nil, at: t1)
            XCTAssertEqual(state.record.status, status, "\(reason)")
        }
        var refused = fresh()
        refused.beginTurn(prompt: "x", images: [], at: t0)
        refused.endTurn(.refusal, error: nil, at: t1)
        XCTAssertEqual(refused.record.lastMessage, "agent 拒绝继续这次请求", "没有正文时说清楚为什么失败")
    }

    func testErrorFailsTheTurn() {
        var state = fresh()
        state.beginTurn(prompt: "x", images: [], at: t0)
        state.endTurn(nil, error: "agent 进程退出了", at: t1)
        XCTAssertEqual(state.record.status, .failed)
        XCTAssertEqual(state.record.lastMessage, "agent 进程退出了")
    }

    func testPermissionMakesItWaitingApproval() throws {
        var state = fresh()
        state.beginTurn(prompt: "x", images: [], at: t0)
        state.apply(.toolCall(try XCTUnwrap(AcpToolCall(json: ["toolCallId": "call_1", "title": "npm test",
                                                                   "kind": "execute", "rawInput": ["command": "npm test"]]))), at: t0)
        let request = try XCTUnwrap(AcpPermissionRequest(params: [
            "sessionId": "s1", "toolCall": ["toolCallId": "call_1"],
            "options": [["optionId": "once", "name": "允许", "kind": "allow_once"]],
        ]))
        state.setPending(request, at: t1)
        XCTAssertEqual(state.record.status, .waitingApproval)
        XCTAssertEqual(state.record.pendingRequest?.id, "call_1")
        XCTAssertEqual(state.record.pendingRequest?.kind, .command)
        XCTAssertEqual(state.record.pendingRequest?.summary, "npm test", "审批请求里没带标题时用之前 tool_call 的")
        XCTAssertEqual(state.record.pendingRequest?.detail, #"{"command":"npm test"}"#)
        state.clearPending(at: t1)
        XCTAssertEqual(state.record.status, .running)
        XCTAssertNil(state.record.pendingRequest)
    }

    /// 协议 3.11：工具调用的标题与 kind 都是空白时，摘要才是电脑写的「工具调用」，带短语；标题空串时退到 kind。
    func testUnnamedToolCallGetsTheToolCallPhrase() throws {
        var state = fresh()
        state.beginTurn(prompt: "x", images: [], at: t0)
        let blank = try XCTUnwrap(AcpPermissionRequest(params: [
            "sessionId": "s1", "toolCall": ["toolCallId": "call_2", "title": " "],
            "options": [["optionId": "once", "name": "允许", "kind": "allow_once"]],
        ]))
        state.setPending(blank, at: t1)
        XCTAssertEqual(state.record.pendingRequest?.summary, "工具调用")
        XCTAssertEqual(state.record.pendingRequest?.summaryPhrase, .toolCall)

        let kindOnly = try XCTUnwrap(AcpPermissionRequest(params: [
            "sessionId": "s1", "toolCall": ["toolCallId": "call_3", "title": "", "kind": "fetch"],
            "options": [["optionId": "once", "name": "允许", "kind": "allow_once"]],
        ]))
        state.setPending(kindOnly, at: t1)
        XCTAssertEqual(state.record.pendingRequest?.summary, "fetch")
        XCTAssertNil(state.record.pendingRequest?.summaryPhrase, "agent 给的 kind 是原文")
    }

    func testTranscriptIdsAreStableAcrossReplay() throws {
        func play(_ state: inout AcpSessionState) throws {
            state.apply(.userMessage(text: "第一问", images: []), at: t0)
            state.apply(.agentMessage(text: "答", images: []), at: t0)
            state.apply(.agentMessage(text: "一", images: []), at: t0)
            state.apply(.toolCall(try XCTUnwrap(AcpToolCall(json: ["toolCallId": "c1", "title": "读文件"]))), at: t0)
            state.apply(.agentMessage(text: "读完了", images: []), at: t0)
            state.apply(.userMessage(text: "第二问", images: []), at: t1)
        }
        var first = fresh()
        try play(&first)
        let ids = first.transcript.entries.map(\.message.id)
        XCTAssertEqual(ids, ["1-1", "1-2", "tool-c1", "1-3", "2-1"])
        XCTAssertEqual(first.transcript.entries[1].message.text, "答一", "同一角色连续的片段合成一条")
        var replay = fresh()
        try play(&replay)
        XCTAssertEqual(replay.transcript.entries.map(\.message.id), ids)
    }

    func testToolUpdateRenamesTheSameLine() throws {
        var state = fresh()
        state.apply(.toolCall(try XCTUnwrap(AcpToolCall(json: ["toolCallId": "c1", "title": "读文件"]))), at: t0)
        state.apply(.toolCallUpdate(try XCTUnwrap(AcpToolCall(json: ["toolCallId": "c1", "title": "读 README.md"]))), at: t0)
        XCTAssertEqual(state.transcript.entries.map(\.message.text), ["读 README.md"])
    }

    func testAgentTitleWinsOverPrompt() {
        var state = fresh()
        state.apply(.sessionInfo(title: "修复登录"), at: t0)
        state.beginTurn(prompt: "随便说点什么", images: [], at: t0)
        XCTAssertEqual(state.record.title, "修复登录")
    }

    func testImagesBecomeImageSources() {
        var state = fresh()
        state.beginTurn(prompt: "", images: [AcpImage(base64: "iVBORw0KGgo=", mimeType: "image/png")], at: t0)
        XCTAssertEqual(state.transcript.entries.first?.images.count, 1)
        XCTAssertEqual(state.transcript.entries.first?.message.role, .user)
    }

    // MARK: - 轮次边界（打断/终端发起的轮次不能粘连）

    func testInterruptedTurnThenNewPromptAreTwoSeparateUserItems() {
        var state = fresh()
        state.beginTurn(prompt: "修一下登录", images: [], at: t0)
        state.endTurn(.cancelled, error: nil, at: t0)
        state.beginTurn(prompt: "算了改注册", images: [], at: t1)
        XCTAssertEqual(state.transcript.entries.map(\.message.text), ["修一下登录", "算了改注册"],
                        "打断后重新发的 prompt 不能跟上一轮的粘成一条")
        XCTAssertEqual(state.transcript.entries.map(\.message.id), ["1-1", "2-1"])
    }

    func testTwoTerminalTurnsProduceSeparateAgentItems() {
        var state = fresh()
        state.beginTurn(prompt: "", images: [], at: t0)
        state.apply(.agentMessage(text: "第一轮回复", images: []), at: t0)
        state.endTurn(.endTurn, error: nil, at: t0)
        state.beginTurn(prompt: "", images: [], at: t1)
        state.apply(.agentMessage(text: "第二轮回复", images: []), at: t1)
        state.endTurn(.endTurn, error: nil, at: t1)
        let ids = state.transcript.entries.map(\.message.id)
        XCTAssertEqual(state.transcript.entries.map(\.message.text), ["第一轮回复", "第二轮回复"])
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1], "两轮终端起的对话不能共用同一个 id")
    }

    func testTerminalTurnWhenUserMessageChunkArrivesBeforeBeginTurn() throws {
        var state = fresh()
        state.apply(.userMessage(text: "终端里敲的", images: []), at: t0)
        state.beginTurn(prompt: "", images: [], at: t0)
        state.apply(.agentMessage(text: "回复终端", images: []), at: t0)
        state.endTurn(.endTurn, error: nil, at: t0)
        XCTAssertEqual(state.transcript.entries.map(\.message.text), ["终端里敲的", "回复终端"],
                        "user_message_chunk 抢在 beginTurn 之前到达也只能出现一次")
    }

    func testEchoOfPhonePromptDuringRunningTurnIsIgnored() {
        var state = fresh()
        state.beginTurn(prompt: "修一下登录", images: [], at: t0)
        state.apply(.userMessage(text: "修一下登录", images: []), at: t0)
        state.apply(.agentMessage(text: "好的", images: []), at: t0)
        state.endTurn(.endTurn, error: nil, at: t1)
        XCTAssertEqual(state.transcript.entries.map(\.message.text), ["修一下登录", "好的"],
                        "agent 把手机发的 prompt 原样回显时不能重复记一条")
    }

    func testLiveTurnIdsMatchReplayIdsForNormalSequence() {
        var live = fresh()
        live.beginTurn(prompt: "第一问", images: [], at: t0)
        live.apply(.agentMessage(text: "答一", images: []), at: t0)
        live.endTurn(.endTurn, error: nil, at: t0)
        live.beginTurn(prompt: "第二问", images: [], at: t1)
        live.apply(.agentMessage(text: "答二", images: []), at: t1)
        live.endTurn(.endTurn, error: nil, at: t1)

        var replay = fresh()
        replay.apply(.userMessage(text: "第一问", images: []), at: t0)
        replay.apply(.agentMessage(text: "答一", images: []), at: t0)
        replay.apply(.userMessage(text: "第二问", images: []), at: t1)
        replay.apply(.agentMessage(text: "答二", images: []), at: t1)

        let liveIds = live.transcript.entries.map(\.message.id)
        XCTAssertEqual(liveIds, replay.transcript.entries.map(\.message.id))
        XCTAssertEqual(liveIds, ["1-1", "1-2", "2-1", "2-2"])
    }

    // MARK: - 挂起审批结束后复原状态

    func testClearPendingRestoresStatusFromBeforePendingWhenNotRunning() throws {
        var state = fresh()
        state.beginTurn(prompt: "x", images: [], at: t0)
        state.endTurn(.endTurn, error: nil, at: t0)
        XCTAssertEqual(state.record.status, .completed)
        let request = try XCTUnwrap(AcpPermissionRequest(params: [
            "sessionId": "s1", "toolCall": ["toolCallId": "call_1"],
            "options": [["optionId": "once", "name": "允许", "kind": "allow_once"]],
        ]))
        state.setPending(request, at: t1)
        XCTAssertEqual(state.record.status, .waitingApproval)
        state.clearPending(at: t1)
        XCTAssertEqual(state.record.status, .completed, "一轮已经结束后清审批不能把状态错改回运行中")
        XCTAssertNil(state.record.pendingRequest)
    }

    func testSecondPendingKeepsOriginalStatus() throws {
        var state = fresh()
        state.beginTurn(prompt: "x", images: [], at: t0)
        state.endTurn(.endTurn, error: nil, at: t0)
        let first = try XCTUnwrap(AcpPermissionRequest(params: ["sessionId": "s1", "toolCall": ["toolCallId": "call_1"], "options": []]))
        let second = try XCTUnwrap(AcpPermissionRequest(params: ["sessionId": "s1", "toolCall": ["toolCallId": "call_2"], "options": []]))
        state.setPending(first, at: t1)
        state.setPending(second, at: t1)
        XCTAssertEqual(state.record.pendingRequest?.id, "call_2")
        state.clearPending(at: t1)
        XCTAssertEqual(state.record.status, .completed, "连着来两个审批，清掉后仍回到最初的状态")
    }
}
