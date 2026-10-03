import Foundation
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

/// 两个 peer 背靠背：一边 send 的每一行按顺序喂给另一边（单个读循环，和真实传输一样串行）。
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

/// 一个只挂着若干 ACP agent 的 TaskStore（一档全都探测不到）。
func makeAcpStore(_ ids: [String] = ["my-agent"], agentId: String = "agent-1") -> TaskStore {
    let registry = ConnectorRegistry(descriptors: ConnectorDescriptor.all(codexBinary: { nil }, claudeBinary: { nil },
                                                                          hermesBinary: { nil }, piBinary: { nil },
                                                                          openClawBinary: { nil },
                                                                          dshPaths: { DshPaths(home: URL(fileURLWithPath: "/nonexistent-dsh")) },
                                                                          dshInstallation: { nil }))
    registry.setAcpEntries(ids.map {
        ConnectorRegistry.AcpEntry(id: $0, displayName: $0 == "my-agent" ? "My Agent" : $0, defaultEnabled: true,
                                   canStartTask: true, status: .ok, lastError: nil)
    })
    return TaskStore(identity: AgentIdentity(agentId: agentId, name: "Mac", appVersion: "1.0"), connectors: registry)
}

func acpRecord(_ connectorId: String, _ sessionId: String, status: TaskStatus = .completed,
               updatedAt: String = "2026-09-26T08:00:00Z", cwd: String = "/Users/me/app") -> TaskRecord {
    var record = AcpSessionState.newRecord(connectorId: connectorId, sessionId: sessionId, cwd: cwd, title: "t",
                                           origin: .watch, controllable: true, at: updatedAt)
    record.status = status
    return record
}

/// 把 AsyncStream 的迭代器包进 actor：`CodexProcessHandle.readStdout()` 由单个读循环串行调用。
actor StreamReader<Element: Sendable> {
    private var iterator: AsyncStream<Element>.Iterator

    init(_ stream: AsyncStream<Element>) { iterator = stream.makeAsyncIterator() }

    func next() async -> Element? {
        var copy = iterator
        let value = await copy.next()
        iterator = copy
        return value
    }
}

/// 假 agent 的行为。测试在用之前设好，之后只读（`newSessionError` / `loadError` 可以中途改）。
final class FakeAcpBehavior: @unchecked Sendable {
    var capabilities: JSONValue = ["loadSession": false, "promptCapabilities": ["image": false]]
    var authMethods: JSONValue = []
    var listed: [JSONValue] = []
    private let errors = Locked<(newSession: JSONRPCError?, load: JSONRPCError?, resume: JSONRPCError?)>((nil, nil, nil))
    var newSessionError: JSONRPCError? {
        get { errors.withLock { $0.newSession } }
        set { errors.withLock { $0.newSession = newValue } }
    }
    var loadError: JSONRPCError? {
        get { errors.withLock { $0.load } }
        set { errors.withLock { $0.load = newValue } }
    }
    var resumeError: JSONRPCError? {
        get { errors.withLock { $0.resume } }
        set { errors.withLock { $0.resume = newValue } }
    }
    /// 每次 prompt：拿 agent 一侧的 peer 推 update、发审批，返回 stopReason。
    var onPrompt: @Sendable (_ agent: JSONRPCPeer, _ sessionId: String) async throws -> String = { agent, sessionId in
        await agent.notify("session/update", params: [
            "sessionId": .string(sessionId),
            "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "好的"]],
        ])
        return "end_turn"
    }
    var onLoad: @Sendable (_ agent: JSONRPCPeer, _ sessionId: String) async -> Void = { _, _ in }
    /// `session/new` 回应之前先跑它（模拟慢的建会话）。
    var onNewSession: @Sendable () async -> Void = {}
    /// `initialize` 回应之前先跑它（模拟慢的握手）。
    var onInitialize: @Sendable () async -> Void = {}

    let received = Locked<[String]>([])
    let params = Locked<[String: JSONValue]>([:])
    let cancelled = Locked<[String]>([])
    private let counter = Locked(0)

    func nextSessionId() -> String { counter.withLock { $0 += 1; return "sess-\($0)" } }
    func methods() -> [String] { received.withLock { $0 } }
}

/// 内存里的假 ACP agent：实现 `CodexProcessHandle`。stdin 写进来的字节交给 agent 一侧的 `JSONRPCPeer`，
/// agent 发的行从 stdout 读出去。
final class FakeAcpAgent: CodexProcessHandle, @unchecked Sendable {
    let peer: JSONRPCPeer
    private let output: StreamReader<Data>
    private let outputSink: AsyncStream<Data>.Continuation
    private let inputSink: AsyncStream<Data>.Continuation
    private let exitBox = OneShotContinuation<CodexProcessExit>()
    let terminated = Locked(false)

    private init() {
        let (output, outputSink) = AsyncStream<Data>.makeStream()
        self.output = StreamReader(output)
        self.outputSink = outputSink
        peer = JSONRPCPeer(send: { outputSink.yield(Data(($0 + "\n").utf8)) })
        let (input, inputSink) = AsyncStream<Data>.makeStream()
        self.inputSink = inputSink
        let peer = self.peer
        Task { for await chunk in input { await peer.receive(chunk) } }
    }

    static func make(_ behavior: FakeAcpBehavior) async -> FakeAcpAgent {
        let agent = FakeAcpAgent()
        let peer = agent.peer
        await peer.setHandlers(request: { method, params in
            behavior.received.withLock { $0.append(method) }
            behavior.params.withLock { $0[method] = params }
            switch method {
            case "initialize":
                await behavior.onInitialize()
                return ["protocolVersion": 1, "agentCapabilities": behavior.capabilities, "authMethods": behavior.authMethods]
            case "session/new":
                if let error = behavior.newSessionError { throw error }
                await behavior.onNewSession()
                return ["sessionId": .string(behavior.nextSessionId())]
            case "session/load":
                if let error = behavior.loadError { throw error }
                await behavior.onLoad(peer, params["sessionId"]?.stringValue ?? "")
                return .null
            case "session/resume":
                if let error = behavior.resumeError { throw error }
                return .null
            case "session/prompt":
                return ["stopReason": .string(try await behavior.onPrompt(peer, params["sessionId"]?.stringValue ?? ""))]
            case "session/list":
                return ["sessions": .array(behavior.listed)]
            default:
                throw JSONRPCError(code: JSONRPCError.methodNotFound, message: method)
            }
        }, notification: { method, params in
            behavior.received.withLock { $0.append(method) }
            if method == "session/cancel" {
                behavior.cancelled.withLock { $0.append(params["sessionId"]?.stringValue ?? "") }
            }
        })
        return agent
    }

    func readStdout() async throws -> Data? { await output.next() }
    func writeStdin(_ data: Data) async throws { inputSink.yield(data) }

    func terminate() {
        terminated.withLock { $0 = true }
        finish(CodexProcessExit(status: 0))
    }

    /// 模拟崩溃。
    func crash(reason: String = "segfault") { finish(CodexProcessExit(status: 139, reason: reason)) }

    func waitForExit() async -> CodexProcessExit {
        (try? await exitBox.value()) ?? CodexProcessExit(status: -1)
    }

    private func finish(_ exit: CodexProcessExit) {
        outputSink.finish()
        inputSink.finish()
        _ = exitBox.resume(returning: exit)
    }
}

/// 每次 launch 取下一个预先建好的假 agent；取完了就报错（测试据此断言"没有再起进程"）。
final class FakeAgentQueue: @unchecked Sendable {
    private let agents: Locked<[FakeAcpAgent]>
    let requests = Locked<[AcpLaunchRequest]>([])

    init(_ agents: [FakeAcpAgent]) { self.agents = Locked(agents) }

    var factory: AcpLauncherFactory {
        { request in
            self.requests.withLock { $0.append(request) }
            return FakeLauncher(queue: self)
        }
    }

    func next() throws -> FakeAcpAgent {
        let agent = agents.withLock { list in list.isEmpty ? nil : list.removeFirst() }
        guard let agent else { throw ConnectorError("没有更多假 agent 了") }
        return agent
    }

    private struct FakeLauncher: CodexProcessLauncher {
        let queue: FakeAgentQueue
        func launch() throws -> any CodexProcessHandle { try queue.next() }
    }
}

/// 一个带一个假 agent 的连接器。`health` 记下每次健康回报。
struct AcpHarness {
    let store: TaskStore
    let behavior: FakeAcpBehavior
    let agent: FakeAcpAgent
    let queue: FakeAgentQueue
    let connector: AcpConnector
    let health: Locked<[(ConnectorInfo.Status, String?)]>
    /// 标了 `handshakeFailed` 的健康回报次数。
    let handshakeFailures: Locked<Int>

    static func make(behavior: FakeAcpBehavior = FakeAcpBehavior(), executable: String? = "/usr/local/bin/my-agent",
                     tools: AgentToolsConfiguration? = nil, idleTimeout: TimeInterval = 600,
                     identity: AcpTaskIdentity? = nil,
                     initializeTimeout: TimeInterval = AcpClient.initializeTimeout,
                     directoryProbe: DirectoryProbe = .live()) async -> AcpHarness {
        let store = makeAcpStore()
        let agent = await FakeAcpAgent.make(behavior)
        let queue = FakeAgentQueue([agent])
        let health = Locked<[(ConnectorInfo.Status, String?)]>([])
        let handshakeFailures = Locked(0)
        let spec = AcpAgentSpec(id: "my-agent", name: "My Agent", executable: executable, arguments: ["--acp"],
                                environment: [:], origin: .manifest, defaultEnabled: true)
        let connector = AcpConnector(spec: spec, identity: identity, store: store, launcher: queue.factory, tools: { tools },
                                     directoryProbe: directoryProbe,
                                     clientVersion: "1.0", idleTimeout: idleTimeout,
                                     initializeTimeout: initializeTimeout,
                                     onHealth: { _, status, message, handshakeFailed in
                                         health.withLock { $0.append((status, message)) }
                                         if handshakeFailed { handshakeFailures.withLock { $0 += 1 } }
                                     },
                                     onTasksChanged: {})
        return AcpHarness(store: store, behavior: behavior, agent: agent, queue: queue, connector: connector, health: health,
                          handshakeFailures: handshakeFailures)
    }

    func task(_ id: String) async -> TaskRecord? { await store.task(id: id) }
}
