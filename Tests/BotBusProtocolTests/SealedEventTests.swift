import XCTest
@testable import BotBusProtocol

final class SealedEventTests: XCTestCase {
    /// 分发器发出的对话记录 agentId 是空串；Relay 按连接把 agentId 盖成本机的再并进快照。
    /// 密封时必须已经按本机 agentId 钉 AAD，手机才解得开（2026-09-26 端到端测试里整份快照因此解不开）。
    func testTaskMessagesSealedWithAgentIdTheRelayStamps() throws {
        let sealer = PairSealer(pairKey: .random())
        let messages = TaskMessages(taskId: "claude:t1", agentId: "",
                                    messages: [Message(id: "m1", role: .agent, text: "hi", createdAt: "2026-09-26T00:00:00Z")],
                                    hasMore: false, fetchedAt: "2026-09-26T00:00:01Z")
        let sealed = try SealedEvent(sealing: .taskMessages(messages), agentId: "agent-a", sealer: sealer)
        var stamped = try XCTUnwrap(sealed.taskMessages)
        XCTAssertEqual(stamped.agentId, "agent-a")
        stamped.agentId = "agent-a"  // Relay 的 recordMessages：{ ...messages, agentId }
        let opened = try TaskMessages(opening: stamped, sealer: sealer.content)
        XCTAssertEqual(opened.agentId, "agent-a")
        XCTAssertEqual(opened.messages.map(\.text), ["hi"])
    }
}
