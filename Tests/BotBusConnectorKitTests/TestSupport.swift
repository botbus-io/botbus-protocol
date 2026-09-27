import Foundation
import XCTest
@testable import BotBusConnectorKit
import BotBusProtocol

/// 线程安全的小盒子，测试里跨任务收集数据。
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
    var current: Value { withLock { $0 } }
}

/// 背靠背的两个 `JSONRPCPeer`（与 BotBusConnectors 测试里的 `AcpTestSupport` 各留一份）。
final class PeerWire: @unchecked Sendable {
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() { (stream, continuation) = AsyncStream<String>.makeStream() }

    func push(_ line: String) { continuation.yield(line) }
    func finish() { continuation.finish() }

    @discardableResult
    func pump(into peer: JSONRPCPeer) -> Task<Void, Never> {
        let stream = self.stream
        return Task { for await line in stream { await peer.receive(Data((line + "\n").utf8)) } }
    }
}

func connectedPeers() -> (client: JSONRPCPeer, agent: JSONRPCPeer) {
    let toAgent = PeerWire()
    let toClient = PeerWire()
    let client = JSONRPCPeer(send: { toAgent.push($0) })
    let agent = JSONRPCPeer(send: { toClient.push($0) })
    toAgent.pump(into: agent)
    toClient.pump(into: client)
    return (client, agent)
}

/// 轮询直到条件成立或超时。
func eventually(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// XCTest 的 autoclosure 不支持 await：先等条件再断言，失败仍归到调用行。
func assertEventually(timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
                      _ condition: @escaping () async -> Bool) async {
    let satisfied = await eventually(timeout: timeout, condition)
    XCTAssertTrue(satisfied, "condition not met within \(timeout)s", file: file, line: line)
}

/// 一个只挂着若干 ACP agent 的 TaskStore：一档全都探测不到（Codex / Claude 照旧上报为不可用，其余不上报）。
func makeAcpStore(_ ids: [String] = ["my-agent"], agentId: String = "agent-1") -> TaskStore {
    let descriptors = ConnectorKind.allCases.compactMap { kind -> ConnectorDescriptor? in
        guard kind != .acp else { return nil }
        return ConnectorDescriptor(kind: kind, displayName: kind.rawValue, defaultEnabled: true,
                                   reportsWhenUnavailable: kind == .codex || kind == .claude) {
            ConnectorProbe(available: false, status: .degraded, lastError: "本机未检测到")
        }
    }
    let registry = ConnectorRegistry(descriptors: descriptors)
    registry.setAcpEntries(ids.map {
        ConnectorRegistry.AcpEntry(id: $0, displayName: $0 == "my-agent" ? "My Agent" : $0, defaultEnabled: true,
                                   canStartTask: true, status: .ok, lastError: nil)
    })
    return TaskStore(identity: AgentIdentity(agentId: agentId, name: "Mac", appVersion: "1.0"), connectors: registry)
}

/// 一条 ACP 会话的任务记录（形状同 BotBusConnectors 里 `AcpSessionState.newRecord`）。
func acpRecord(_ connectorId: String, _ sessionId: String, status: TaskStatus = .completed,
               updatedAt: String = "2026-09-26T08:00:00Z", cwd: String = "/Users/me/app") -> TaskRecord {
    TaskRecord(id: "acp:\(connectorId):\(sessionId)", agentId: "", source: .acp, title: "t",
               projectPath: cwd, projectName: URL(fileURLWithPath: cwd).lastPathComponent, status: status,
               origin: .watch, controllable: true, startedAt: updatedAt, updatedAt: updatedAt,
               connectorId: connectorId)
}
