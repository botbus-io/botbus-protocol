import Foundation
import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class AcpMessagesTests: XCTestCase {
    func testCapabilitiesFromInitializeResult() {
        let result: JSONValue = [
            "protocolVersion": 1,
            "agentCapabilities": [
                "loadSession": true,
                "promptCapabilities": ["image": true],
                "sessionCapabilities": ["list": [:]],
            ],
            "authMethods": [["id": "oauth", "name": "登录"]],
        ]
        let capabilities = AcpCapabilities(initializeResult: result)
        XCTAssertEqual(capabilities, AcpCapabilities(protocolVersion: 1, loadSession: true, images: true,
                                                     listSessions: true, authMethodCount: 1))
        XCTAssertEqual(AcpCapabilities(initializeResult: ["protocolVersion": 1]),
                       AcpCapabilities(protocolVersion: 1))
    }

    func testToolCallDetailPrefersRawInput() throws {
        let call = try XCTUnwrap(AcpToolCall(json: [
            "toolCallId": "call_1", "title": "npm test", "kind": "execute", "status": "pending",
            "rawInput": ["command": "npm test"],
        ]))
        XCTAssertEqual(call.detail, #"{"command":"npm test"}"#)
        XCTAssertEqual(call.pendingKind, .command)
        let text = try XCTUnwrap(AcpToolCall(json: [
            "toolCallId": "call_2", "kind": "edit",
            "content": [["type": "content", "content": ["type": "text", "text": "改 README"]]],
        ]))
        XCTAssertEqual(text.detail, "改 README")
        XCTAssertEqual(text.pendingKind, .fileChange)
        XCTAssertEqual(AcpToolCall(json: ["toolCallId": "c", "kind": "fetch"])?.pendingKind, .permission)
        XCTAssertNil(AcpToolCall(json: ["title": "没有 id"]))
    }

    func testToolCallDetailIgnoresNonTextContent() throws {
        let call = try XCTUnwrap(AcpToolCall(json: [
            "toolCallId": "call_diff", "kind": "edit",
            "content": [["type": "diff", "path": "README.md", "oldText": "旧", "newText": "新"]],
        ]))
        XCTAssertNil(call.detail, "只有 diff、没有文本内容也没有 rawInput，认不出细节")
    }

    func testToolCallUpdateMergesOnlyChangedFields() throws {
        let original = try XCTUnwrap(AcpToolCall(json: ["toolCallId": "c", "title": "读文件", "kind": "read", "status": "pending"]))
        let update = try XCTUnwrap(AcpToolCall(json: ["toolCallId": "c", "status": "completed"]))
        let merged = original.merging(update)
        XCTAssertEqual(merged.title, "读文件")
        XCTAssertEqual(merged.kind, "read")
        XCTAssertEqual(merged.status, "completed")
    }

    func testToolCallUpdateKeepsRawInputWhenUpdateOnlyHasContentText() throws {
        let original = try XCTUnwrap(AcpToolCall(json: [
            "toolCallId": "call_1", "kind": "execute", "status": "pending",
            "rawInput": ["command": "rm -rf ~/x"],
        ]))
        // 审批请求里的 toolCall（ToolCallUpdate）常常只带一句给人看的说明，没有 rawInput。
        let approvalUpdate = try XCTUnwrap(AcpToolCall(json: [
            "toolCallId": "call_1",
            "content": [["type": "content", "content": ["type": "text", "text": "清理构建目录"]]],
        ]))
        let merged = original.merging(approvalUpdate)
        XCTAssertEqual(merged.detail, #"{"command":"rm -rf ~/x"}"#, "说明文字不能顶掉真正要跑的命令")

        // 完成时的 tool_call_update 带了新的 rawInput，这才应该覆盖。
        let finishedUpdate = try XCTUnwrap(AcpToolCall(json: [
            "toolCallId": "call_1", "status": "completed",
            "rawInput": ["command": "rm -rf ~/y"],
        ]))
        XCTAssertEqual(merged.merging(finishedUpdate).detail, #"{"command":"rm -rf ~/y"}"#, "新的 rawInput 应当覆盖旧的")
    }

    func testSessionUpdateParsing() {
        XCTAssertEqual(AcpSessionUpdate(json: ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "好"]]),
                       .agentMessage(text: "好", images: []))
        XCTAssertEqual(AcpSessionUpdate(json: ["sessionUpdate": "user_message_chunk",
                                               "content": ["type": "image", "mimeType": "image/png", "data": "iVBO"]]),
                       .userMessage(text: "", images: [AcpImage(base64: "iVBO", mimeType: "image/png")]))
        XCTAssertEqual(AcpSessionUpdate(json: ["sessionUpdate": "agent_thought_chunk"]), .thought)
        XCTAssertEqual(AcpSessionUpdate(json: ["sessionUpdate": "session_info_update", "title": "修登录"]),
                       .sessionInfo(title: "修登录"))
        XCTAssertEqual(AcpSessionUpdate(json: ["sessionUpdate": "plan"]), .other("plan"))
        XCTAssertEqual(AcpSessionUpdate(json: ["sessionUpdate": "tool_call"]), .other("tool_call"), "缺 toolCallId 当不认识")
    }

    func testPermissionOptionChoice() throws {
        let request = try XCTUnwrap(AcpPermissionRequest(params: [
            "sessionId": "s1",
            "toolCall": ["toolCallId": "call_1", "title": "rm -rf build", "kind": "execute"],
            "options": [
                ["optionId": "always", "name": "总是允许", "kind": "allow_always"],
                ["optionId": "once", "name": "允许一次", "kind": "allow_once"],
                ["optionId": "never", "name": "总是拒绝", "kind": "reject_always"],
            ],
        ]))
        XCTAssertEqual(request.optionId(for: .allow), "once", "手机上点一下不能变成永久授权")
        XCTAssertEqual(request.optionId(for: .deny), "never", "没有一次性的拒绝才退到总是")
        let onlyAllow = try XCTUnwrap(AcpPermissionRequest(params: [
            "sessionId": "s1", "toolCall": ["toolCallId": "c"],
            "options": [["optionId": "ok", "name": "OK", "kind": "allow_once"]],
        ]))
        XCTAssertNil(onlyAllow.optionId(for: .deny))
    }

    /// 协议 2.14：allow 类选项列成「允许范围」，once 在前；手机选中的名字对回 optionId，对不上就按老规则。
    func testPermissionOptionsBecomeApprovalChoices() throws {
        let request = try XCTUnwrap(AcpPermissionRequest(params: [
            "sessionId": "s1", "toolCall": ["toolCallId": "c"],
            "options": [
                ["optionId": "always", "name": "总是允许", "kind": "allow_always"],
                ["optionId": "once", "name": "允许一次", "kind": "allow_once"],
                ["optionId": "dup", "name": "允许一次", "kind": "allow_once"],
                ["optionId": "never", "name": "总是拒绝", "kind": "reject_always"],
            ],
        ]))
        XCTAssertEqual(request.pendingQuestions, [PendingQuestion(id: "scope", question: "允许范围",
                                                                  options: [PendingOption(label: "允许一次"),
                                                                            PendingOption(label: "总是允许")])])
        XCTAssertEqual(request.optionId(for: .allow, answers: ["scope": ["总是允许"]]), "always")
        XCTAssertEqual(request.optionId(for: .allow, answers: ["scope": ["允许一次"]]), "once", "同名取第一个")
        XCTAssertEqual(request.optionId(for: .allow, answers: ["scope": ["写错了"]]), "once")
        XCTAssertEqual(request.optionId(for: .allow, answers: nil), "once")
        XCTAssertEqual(request.optionId(for: .deny, answers: ["scope": ["总是允许"]]), "never", "拒绝不看范围")
        let onlyReject = try XCTUnwrap(AcpPermissionRequest(params: [
            "sessionId": "s1", "toolCall": ["toolCallId": "c"],
            "options": [["optionId": "no", "name": "不", "kind": "reject_once"]],
        ]))
        XCTAssertNil(onlyReject.pendingQuestions, "没有可选的允许就不出范围")
    }

    func testPermissionOutcomeJSON() {
        XCTAssertEqual(AcpPermissionOutcome.selected(optionId: "once").json,
                       ["outcome": ["outcome": "selected", "optionId": "once"]])
        XCTAssertEqual(AcpPermissionOutcome.cancelled.json, ["outcome": ["outcome": "cancelled"]])
    }

    func testMcpServerEncodesEnvAsNameValueList() {
        let server = AcpMcpServer(name: "botbus", command: "/bin/botbus", args: ["mcp"],
                                  env: ["B": "2", "A": "1"])
        XCTAssertEqual(server.json, [
            "name": "botbus", "command": "/bin/botbus", "args": ["mcp"],
            "env": [["name": "A", "value": "1"], ["name": "B", "value": "2"]],
        ])
    }

    func testSessionInfoParsing() throws {
        let info = try XCTUnwrap(AcpSessionInfo(json: ["sessionId": "s", "cwd": "/p", "title": "t",
                                                       "updatedAt": "2026-09-26T08:00:00.123Z"]))
        XCTAssertEqual(info.title, "t")
        XCTAssertEqual(info.updatedAt.map { ProtocolJSON.timestamp($0) }, "2026-09-26T08:00:00Z")
        XCTAssertNil(AcpSessionInfo(json: ["sessionId": "s"]), "cwd 是必需的")
    }

    func testHelloParsing() throws {
        let hello = try XCTUnwrap(AcpHello(params: [
            "id": "my-agent", "version": 1, "pid": 42,
            "capabilities": ["prompt": true, "cancel": false],
        ]))
        XCTAssertEqual(hello.id, "my-agent")
        XCTAssertEqual(hello.capabilities, AcpHello.Capabilities(prompt: true, cancel: false, newSession: false))
        XCTAssertNil(AcpHello(params: ["version": 1]))
        XCTAssertEqual(AcpHello.rejection("不认识"), ["accepted": false, "reason": "不认识"])
    }

    func testClientPromptSendsTextAndImages() async throws {
        let (client, agent) = connectedPeers()
        let captured = Locked<JSONValue>(.null)
        await agent.setHandlers(request: { method, params in
            XCTAssertEqual(method, "session/prompt")
            captured.withLock { $0 = params }
            return ["stopReason": "cancelled"]
        }, notification: nil)
        let stop = try await AcpClient(peer: client).prompt("s1", text: "看图", images: [AcpImage(base64: "AA==", mimeType: "image/png")])
        XCTAssertEqual(stop, .cancelled)
        XCTAssertEqual(captured.withLock { $0 }, [
            "sessionId": "s1",
            "prompt": [["type": "text", "text": "看图"], ["type": "image", "mimeType": "image/png", "data": "AA=="]],
        ])
    }

    func testClientPromptRejectsEmptyMessage() async {
        let (client, agent) = connectedPeers()
        await agent.setHandlers(request: { method, _ in
            XCTFail("不该发出请求：\(method)")
            return .null
        }, notification: nil)
        do {
            _ = try await AcpClient(peer: client).prompt("s1", text: "", images: [])
            XCTFail("应当拒绝空消息")
        } catch {
            XCTAssertEqual(error.localizedDescription, "消息不能为空")
        }
    }

    func testClientRejectsUnknownProtocolVersion() async {
        let (client, agent) = connectedPeers()
        await agent.setHandlers(request: { _, _ in ["protocolVersion": 2] }, notification: nil)
        do {
            _ = try await AcpClient(peer: client).initialize(clientVersion: "1.0")
            XCTFail("应当拒绝")
        } catch {
            XCTAssertEqual(error.localizedDescription, "不支持的 ACP 版本：2")
        }
    }

    func testListSessionsFollowsCursor() async throws {
        let (client, agent) = connectedPeers()
        await agent.setHandlers(request: { _, params in
            if params["cursor"]?.stringValue == "p2" {
                return ["sessions": [["sessionId": "b", "cwd": "/b"]]]
            }
            return ["sessions": [["sessionId": "a", "cwd": "/a"]], "nextCursor": "p2"]
        }, notification: nil)
        let sessions = try await AcpClient(peer: client).listSessions()
        XCTAssertEqual(sessions.map(\.sessionId), ["a", "b"])
    }
}
