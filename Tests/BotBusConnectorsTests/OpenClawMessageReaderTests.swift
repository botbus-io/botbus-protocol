import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// `chat.history` → 协议消息。形状照 `llm-core` 的 transcript 消息：user / assistant（text、thinking、toolCall 块）/ toolResult。
final class OpenClawMessageReaderTests: XCTestCase {
    private let base: Int64 = 1_790_000_000_000

    private func history(_ entries: [JSONValue], hasMore: Bool? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["messages": .array(entries), "sessionInfo": ["key": "agent:main:main"]]
        if let hasMore { object["hasMore"] = .bool(hasMore) }
        return .object(object)
    }

    func testMapsUserAssistantAndToolCalls() {
        let payload = history([
            ["role": "user", "content": "Hello there", "timestamp": .int(base), "__openclaw": ["id": "e1", "seq": 1]],
            ["role": "assistant", "timestamp": .int(base + 1000), "__openclaw": ["id": "e2", "seq": 2],
             "content": [["type": "thinking", "thinking": "let me think"],
                         ["type": "text", "text": "Sure,"],
                         ["type": "text", "text": "checking."],
                         ["type": "toolCall", "id": "t1", "name": "exec", "arguments": ["command": "ls -la"]],
                         ["type": "text", "text": "Done."]]],
            ["role": "toolResult", "toolCallId": "t1", "toolName": "exec", "content": [["type": "text", "text": "huge output"]],
             "isError": false, "timestamp": .int(base + 2000), "__openclaw": ["id": "e3", "seq": 3]],
            ["role": "system", "__openclaw": ["id": "c1", "kind": "compaction", "tokensBefore": 100]],
            ["role": "user", "content": [["type": "text", "text": "runtime ctx"]], "runtimeContextCarrier": true,
             "timestamp": .int(base + 3000), "__openclaw": ["id": "e4", "seq": 4]],
            ["role": "assistant", "timestamp": .int(base + 4000), "__openclaw": ["id": "e5", "seq": 5],
             "content": [["type": "toolCall", "id": "t2", "name": "read", "arguments": .string(#"{"path":"/repo/Sources/App.swift"}"#)],
                         ["type": "toolCall", "id": "t3", "name": "web_search", "arguments": ["query": "swift"]]]],
            ["role": "user", "content": [["type": "text", "text": "  "], ["type": "image", "data": "…", "mimeType": "image/png"]],
             "timestamp": .int(base + 5000), "__openclaw": ["id": "e6", "seq": 6]],
        ])
        let messages = OpenClawMessageReader.entries(from: payload).map(\.message)
        XCTAssertEqual(messages.map(\.id), ["e1", "e2", "e2#1", "e2#2", "e5", "e5#1"])
        XCTAssertEqual(messages.map(\.role), [.user, .agent, .tool, .agent, .tool, .tool])
        XCTAssertEqual(messages.map(\.text), ["Hello there", "Sure,\nchecking.", "$ ls -la", "Done.",
                                              "调用 read：App.swift", "调用 web_search"])
        XCTAssertEqual(messages[0].createdAt, ProtocolJSON.timestamp(Date(timeIntervalSince1970: 1_790_000_000)))
        XCTAssertEqual(messages[1].createdAt, ProtocolJSON.timestamp(Date(timeIntervalSince1970: 1_790_000_001)))
    }

    func testSiblingRowsSharingAnEntryIdGetDistinctStableIds() {
        let payload = history([
            ["role": "user", "content": "first", "timestamp": .int(base), "__openclaw": ["id": "e7", "seq": 7]],
            ["role": "assistant", "content": "second", "timestamp": .int(base), "__openclaw": ["id": "e7", "seq": 7]],
            // 没有元数据：按角色 + 时间戳。
            ["role": "assistant", "content": [["type": "text", "text": "third"]], "timestamp": .int(base + 9)],
        ])
        let first = OpenClawMessageReader.entries(from: payload).map(\.message)
        let again = OpenClawMessageReader.entries(from: payload).map(\.message)
        XCTAssertEqual(first.map(\.id), ["e7", "e7~1", "assistant-\(base + 9)"])
        XCTAssertEqual(first, again)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
    }

    func testToleratesOddShapes() {
        // 顶层直接是数组、条目不是对象、没有 role、ISO 时间戳、tool_use 块。
        let payload: JSONValue = [
            "garbage",
            ["content": "no role"],
            ["role": "assistant", "timestamp": "2026-09-24T08:00:00.123Z",
             "content": [["type": "tool_use", "name": "bash", "input": ["cmd": "make test"]]]],
        ]
        let messages = OpenClawMessageReader.entries(from: payload).map(\.message)
        XCTAssertEqual(messages.map(\.text), ["$ make test"])
        XCTAssertEqual(messages.first?.createdAt, "2026-09-24T08:00:00Z")
        XCTAssertTrue(OpenClawMessageReader.entries(from: .null).isEmpty)
        XCTAssertTrue(OpenClawMessageReader.entries(from: ["messages": "nope"]).isEmpty)
    }

    func testUserImagesAreCollected() {
        let image: JSONValue = ["type": "image", "data": .string(TestImage.pngBase64), "mimeType": "image/png"]
        let entries = OpenClawMessageReader.entries(from: history([
            ["role": "user", "content": [image], "timestamp": .int(base), "__openclaw": ["id": "u1"]],
            ["role": "user", "content": [["type": "text", "text": "看"], image], "timestamp": .int(base + 1), "__openclaw": ["id": "u2"]],
            ["role": "assistant", "content": [["type": "text", "text": "好"], image], "timestamp": .int(base + 2), "__openclaw": ["id": "a1"]],
            ["role": "toolResult", "content": [image], "timestamp": .int(base + 3), "__openclaw": ["id": "r1"]],
        ]))
        XCTAssertEqual(entries.map(\.message.id), ["u1", "u2", "a1"])
        XCTAssertEqual(entries.map(\.message.text), ["", "看", "好"])
        XCTAssertEqual(entries[0].images, [.data(TestImage.png, contentType: "image/png")], "只有图也是一条")
        XCTAssertEqual(entries[1].images, [.data(TestImage.png, contentType: "image/png")])
        XCTAssertEqual(entries[2].images, [], "assistant 的图不取")
        XCTAssertTrue(entries.allSatisfy { $0.pathCandidates.isEmpty })
    }

    func testLongTextIsPreserved() {
        let long = String(repeating: "a", count: 5000)
        let messages = OpenClawMessageReader.entries(from: history([["role": "user", "content": .string(long), "timestamp": .int(base)]])).map(\.message)
        XCTAssertEqual(messages.first?.text.count, 5000, "user/agent 消息不截断")
    }

    func testLimitAndHasMore() async throws {
        let entries: [JSONValue] = (0..<5).map {
            ["role": "user", "content": .string("m\($0)"), "timestamp": .int(base + Int64($0)), "__openclaw": ["id": .string("e\($0)")]]
        }
        let requested = Locked<[(String, Int)]>([])
        let reader = OpenClawMessageReader { key, limit in
            requested.withLock { $0.append((key, limit)) }
            return self.history(entries)
        }
        let (messages, hasMore) = try await reader.messages(taskId: "openclaw:agent:main:telegram:dm:42", limit: 3)
        XCTAssertEqual(messages.map(\.text), ["m2", "m3", "m4"])
        XCTAssertTrue(hasMore)
        XCTAssertEqual(requested.current.first?.0, "agent:main:telegram:dm:42")
        XCTAssertEqual(requested.current.first?.1, OpenClawMessageReader.recordLimit(forConversation: 3),
                       "Gateway 的 limit 数存储记录（工具调用与结果各占一条），要得比对话条数多")

        let gatewaySaysMore = OpenClawMessageReader { _, _ in self.history(Array(entries.prefix(2)), hasMore: true) }
        let (few, more) = try await gatewaySaysMore.messages(taskId: "openclaw:agent:main:main", limit: 10)
        XCTAssertEqual(few.count, 2)
        XCTAssertTrue(more)

        let complete = OpenClawMessageReader { _, _ in self.history(Array(entries.prefix(2)), hasMore: false) }
        let (_, none) = try await complete.messages(taskId: "openclaw:agent:main:main", limit: 10)
        XCTAssertFalse(none)
    }

    func testRejectsForeignTaskIds() async {
        let reader = OpenClawMessageReader { _, _ in XCTFail("不该发请求"); return .null }
        do {
            _ = try await reader.messages(taskId: "claude:abc", limit: 10)
            XCTFail("应当拒绝")
        } catch {}
    }

    func testFreshConnectionFetchesHistoryAndCloses() async throws {
        let server = FakeOpenClawServer()
        server.history = history([["role": "user", "content": "hi", "timestamp": .int(base), "__openclaw": ["id": "e1"]]])
        let reader = OpenClawMessageReader(config: { OpenClawConfig(port: 18789, token: "t") },
                                           transport: FakeOpenClawTransport(server: server),
                                           clientVersion: "1.0")
        let (messages, _) = try await reader.messages(taskId: "openclaw:agent:main:main", limit: 20)
        XCTAssertEqual(messages.map(\.text), ["hi"])
        let request = try XCTUnwrap(server.requests("chat.history").first?.params)
        XCTAssertEqual(request["sessionKey"]?.stringValue, "agent:main:main")
        XCTAssertEqual(request["limit"]?.intValue, Int64(OpenClawMessageReader.recordLimit(forConversation: 20)))
        XCTAssertEqual(server.requests.first?.method, "connect")
        await assertEventually { server.latest?.closed.current == true }
    }

    func testFreshConnectionSurfacesGatewayDown() async {
        let server = FakeOpenClawServer()
        server.refuseConnections = true
        let reader = OpenClawMessageReader(config: { OpenClawConfig(port: 18789) },
                                           transport: FakeOpenClawTransport(server: server))
        do {
            _ = try await reader.messages(taskId: "openclaw:agent:main:main", limit: 5)
            XCTFail("Gateway 没跑时应当报错")
        } catch {
            XCTAssertEqual(error.localizedDescription, "连不上 OpenClaw Gateway（127.0.0.1:18789）")
        }
    }

    func testPrefersTheConnectorsConnection() async throws {
        let server = FakeOpenClawServer()
        server.history = history([["role": "assistant", "content": [["type": "text", "text": "from connector"]],
                                   "timestamp": .int(base), "__openclaw": ["id": "e1"]]])
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                              connectors: ConnectorRegistry(descriptors: [
                                  ConnectorDescriptor(kind: .openclaw, displayName: "OpenClaw", defaultEnabled: true) {
                                      ConnectorProbe(available: true, status: .ok)
                                  },
                              ]))
        let transport = FakeOpenClawTransport(server: server)
        let connector = OpenClawConnector(store: store, config: { OpenClawConfig(port: 18789) }, transport: transport,
                                          timing: .init(challengeTimeout: 0.2, pingInterval: 0))
        await connector.start()
        defer { Task { await connector.stop() } }
        await assertEventually { await connector.isConnected }

        let reader = OpenClawMessageReader.preferring(connector: connector, config: { OpenClawConfig(port: 18789) },
                                                      transport: transport)
        let (messages, _) = try await reader.messages(taskId: "openclaw:agent:main:main", limit: 10)
        XCTAssertEqual(messages.map(\.text), ["from connector"])
        XCTAssertEqual(server.connections.count, 1, "借用连接器的连接，不另开")
    }

    /// 只有 assistant 的正文带路径候选；用户消息与工具调用摘要不带。
    func testAssistantTextCarriesPathCandidates() {
        let entries = OpenClawMessageReader.entries(from: history([
            ["role": "user", "content": "看 `in/u.png`", "timestamp": .int(base), "__openclaw": ["id": "u1"]],
            ["role": "assistant", "timestamp": .int(base + 1), "__openclaw": ["id": "a1"],
             "content": [["type": "text", "text": "导出了 report.pdf"],
                         ["type": "toolCall", "id": "t1", "name": "read", "arguments": ["path": "out/b.png"]]]],
        ]))
        XCTAssertEqual(entries.map(\.message.id), ["u1", "a1", "a1#1"])
        XCTAssertEqual(entries.map(\.pathCandidates), [[], ["report.pdf"], []])
    }
}
