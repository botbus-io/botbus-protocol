import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

final class PiMessageReaderTests: XCTestCase {
    private var fixture: PiFixture!

    override func setUpWithError() throws { fixture = try PiFixture() }
    override func tearDown() { fixture.remove() }

    private func reader() -> PiMessageReader {
        let paths = fixture.paths
        return PiMessageReader(paths: { paths })
    }

    func testMapsRolesToolCallsAndSkipsThinkingAndToolResults() async throws {
        let ms: Double = 1_790_000_000_000
        try fixture.write(id: "s", lines: [
            PiFixture.header(id: "s", cwd: "/p/demo"),
            PiFixture.user("u1", parent: nil, "看看测试为什么挂了", at: "2026-09-20T01:00:00.000Z"),
            PiFixture.assistant("a1", parent: "u1", text: "我先跑一下测试。", stop: "toolUse", content: [
                ["type": "thinking", "thinking": "内部思考不该出现"],
                ["type": "toolCall", "id": "c1", "name": "bash", "arguments": ["command": "npm test\n  --watch=false"]],
                ["type": "toolCall", "id": "c2", "name": "edit", "arguments": ["path": "src/app.ts", "oldText": "a", "newText": "b"]],
                ["type": "toolCall", "id": "c3", "name": "todo_write", "arguments": ["items": [1, 2]]],
            ], at: "2026-09-20T01:00:05.000Z", extra: ["timestamp": ms]),
            PiFixture.toolResult("r1", parent: "a1"),
            PiFixture.entry("b1", parent: "r1", timestamp: "2026-09-20T01:00:07.000Z",
                            message: ["role": "bashExecution", "command": "git diff", "output": "…"]),
            PiFixture.assistant("a2", parent: "b1", content: [["type": "thinking", "thinking": "只有思考"]],
                                at: "2026-09-20T01:00:08.000Z"),
            PiFixture.assistant("a3", parent: "a2", text: "修好了。", at: "2026-09-20T01:00:09.000Z"),
        ], modifiedAt: Date())

        let (messages, hasMore) = try await reader().messages(taskId: "pi:s", limit: 40)
        XCTAssertFalse(hasMore)
        XCTAssertEqual(messages.map(\.id), ["u1", "a1", "a1#1", "a1#2", "a1#3", "b1", "a3"],
                       "只有思考的 a2 不出气泡；工具调用按 entry id 加 #n")
        XCTAssertEqual(messages.map(\.role), [.user, .agent, .tool, .tool, .tool, .tool, .agent])
        XCTAssertEqual(messages.map(\.text), ["看看测试为什么挂了", "我先跑一下测试。",
                                              "bash: npm test --watch=false", "edit src/app.ts", "todo_write",
                                              "$ git diff", "修好了。"])
        XCTAssertEqual(messages[0].createdAt, "2026-09-20T01:00:00Z")
        XCTAssertEqual(messages[1].createdAt, ProtocolJSON.timestamp(Date(timeIntervalSince1970: ms / 1000)),
                       "消息自带的毫秒时间优先")
        XCTAssertFalse(messages.contains { $0.text.contains("内部思考") })
    }

    func testOnlyCurrentBranchAndStringArguments() async throws {
        try fixture.write(id: "s", lines: [
            PiFixture.header(id: "s", cwd: "/p/demo"),
            PiFixture.user("u1", parent: nil, "问题"),
            PiFixture.assistant("a1", parent: "u1", text: "被放弃的回答"),
            PiFixture.assistant("a2", parent: "u1", stop: "toolUse", content: [
                ["type": "toolCall", "id": "c", "name": "read", "arguments": "{\"path\":\"README.md\"}"],
            ]),
        ], modifiedAt: Date())
        let (messages, _) = try await reader().messages(taskId: "pi:s", limit: 40)
        XCTAssertEqual(messages.map(\.id), ["u1", "a2#1"])
        XCTAssertEqual(messages.last?.text, "read README.md", "arguments 存成 JSON 字符串也认")
    }

    func testLimitKeepsNewestAndReportsHasMore() async throws {
        var lines: [Any] = [PiFixture.header(id: "s", cwd: "/p/demo")]
        var parent: String?
        for index in 0..<30 {
            lines.append(PiFixture.user("u\(index)", parent: parent, "问 \(index)"))
            lines.append(PiFixture.assistant("a\(index)", parent: "u\(index)", text: "答 \(index)"))
            parent = "a\(index)"
        }
        try fixture.write(id: "s", lines: lines, modifiedAt: Date())

        var (messages, hasMore) = try await reader().messages(taskId: "pi:s", limit: 5)
        XCTAssertTrue(hasMore)
        XCTAssertEqual(messages.map(\.id), ["a27", "u28", "a28", "u29", "a29"], "最近的几条，升序")

        (messages, hasMore) = try await reader().messages(taskId: "pi:s", limit: 100)
        XCTAssertEqual(messages.count, TaskMessages.maxMessages, "上限是协议的 40")
        XCTAssertTrue(hasMore)

        (messages, hasMore) = try await reader().messages(taskId: "pi:s", limit: 40)
        XCTAssertEqual(messages.count, 40)
        XCTAssertTrue(hasMore)
    }

    func testLongTextIsPreserved() async throws {
        try fixture.write(id: "s", lines: [
            PiFixture.header(id: "s", cwd: "/p/demo"),
            PiFixture.user("u", parent: nil, String(repeating: "字", count: 5000)),
        ], modifiedAt: Date())
        let (messages, _) = try await reader().messages(taskId: "pi:s", limit: 40)
        XCTAssertEqual(messages.first?.text.count, 5000, "user/agent 消息不截断")
    }

    func testUserImagesAreCollected() async throws {
        let image: [String: Any] = ["type": "image", "data": TestImage.pngBase64, "mimeType": "image/png"]
        try fixture.write(id: "s", lines: [
            PiFixture.header(id: "s", cwd: "/p/demo"),
            PiFixture.user("u1", parent: nil, [image]),
            PiFixture.user("u2", parent: "u1", [["type": "text", "text": "看这张"], image]),
            PiFixture.assistant("a1", parent: "u2", text: "好", content: [image]),
            PiFixture.user("u3", parent: "a1", [["type": "image", "data": "不是 base64", "mimeType": "image/png"]]),
        ], modifiedAt: Date())
        let (entries, hasMore) = try await reader().entries(taskId: "pi:s", limit: 40)
        XCTAssertFalse(hasMore)
        XCTAssertEqual(entries.map(\.message.id), ["u1", "u2", "a1"], "解不出的图不占位，没字就整条不出")
        XCTAssertEqual(entries.map(\.message.text), ["", "看这张", "好"])
        XCTAssertEqual(entries[0].images, [.data(TestImage.png, contentType: "image/png")], "只有图也是一条")
        XCTAssertEqual(entries[1].images, [.data(TestImage.png, contentType: "image/png")])
        XCTAssertEqual(entries[2].images, [], "assistant 的图不取")
        XCTAssertTrue(entries.allSatisfy { $0.pathCandidates.isEmpty })
    }

    func testMissingSessionAndForeignIdThrow() async {
        do {
            _ = try await reader().messages(taskId: "pi:nope", limit: 10)
            XCTFail("找不到文件应当报错")
        } catch {
            XCTAssertEqual((error as? ConnectorError)?.message, "没找到这个 Pi 会话的记录文件")
        }
        do {
            _ = try await reader().messages(taskId: "claude:s", limit: 10)
            XCTFail("别的来源的 id 应当报错")
        } catch {}
    }

    /// 只有 assistant 的正文带路径候选；用户消息与工具调用摘要不带。
    func testAssistantTextCarriesPathCandidates() async throws {
        try fixture.write(id: "s", lines: [
            PiFixture.header(id: "s", cwd: "/p/demo"),
            PiFixture.user("u1", parent: nil, "看 `in/u.png`"),
            PiFixture.assistant("a1", parent: "u1", text: "录好了：`out/demo.mp4`", content: [
                ["type": "toolCall", "id": "c1", "name": "edit", "arguments": ["path": "out/b.png"]],
            ]),
        ], modifiedAt: Date())
        let (entries, _) = try await reader().entries(taskId: "pi:s", limit: 40)
        XCTAssertEqual(entries.map(\.message.id), ["u1", "a1", "a1#1"])
        XCTAssertEqual(entries.map(\.pathCandidates), [[], ["out/demo.mp4"], []])
    }
}
