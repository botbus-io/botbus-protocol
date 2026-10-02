import Foundation
#if canImport(os)
import os
#endif
import BotBusProtocol
import BotBusConnectorKit

/// 所有 ACP agent 的总入口（协议里它们共用 `kind = acp`）：按 `connectorId` 把命令分给各自的 `AcpConnector`，
/// 把它们的任务合起来做 `acp` 这个来源的全量对账，周期刷新 `session/list`，并把健康与能力写进 `ConnectorRegistry`。
///
/// **每个 agent 的开关在这里把关**：`ConnectorRegistry.isEnabled(.acp)` 恒为 true，分发器那一道拦不住单个 agent，
/// 所以命令、对话记录、对账、列表刷新都先查 `isActive(_:)`——没被藏起来（`unverified`）且 `isAcpEnabled(id)`。
/// 两样都显式查，不指望"藏起来的不在注册表条目里、`isAcpEnabled` 自然是 false"。
///
/// **注册表 agent 的第一次握手就是验证**（spec「发现」的计划补丁）：注册表 agent 是按可执行文件名认出来的
/// （`goose` 也可能是数据库迁移工具），第一次拉起若确定不是 ACP agent（起不来、握手前就退出、回的不是 ACP、
/// 协议版本不对），就从注册表条目里拿掉——手机和菜单都不显示、也不再接命令、对账和刷新列表，直到发现结果变了、
/// 它经反向扩展连进来，或者 app 重启。`initialize` 超时不算（冷启动慢的 node agent），照常显示并报 `error`；
/// 登录过期（`auth_required`）说明握手成功了，也照常显示。清单 agent 是开发者自己登记的，失败照旧显示并报 `error`。
///
/// 重入：hub 是 actor，每个 `await` 期间别的调用都可能进来。所以 `sync` 先把自己的状态一次改完再去等连接器，
/// `publishEntries` 全程不 await 连接器（能力由 hub 自己记），对账只让最后开始的那一次落笔。
public actor AcpHub: MultiAgentConnector, MessageReader {
    public typealias ConnectorFactory = @Sendable (
        _ spec: AcpAgentSpec,
        _ onHealth: @escaping AcpConnector.HealthHandler,
        _ onTasksChanged: @escaping @Sendable () async -> Void
    ) -> AcpConnector

    public static let listInterval: TimeInterval = 60
    public static let idleListInterval: TimeInterval = 600
    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "acp")

    public nonisolated var kind: ConnectorKind { .acp }

    private struct Health {
        var status: ConnectorInfo.Status
        var message: String?
    }

    /// 一条已通过 `_botbus/hello` 的反向连接。
    private struct ReverseLinkInfo {
        let agentId: String
        let capabilities: AcpHello.Capabilities
    }

    private let store: TaskStore
    private let makeConnector: ConnectorFactory
    private var connectors: [String: AcpConnector] = [:]
    /// 建连接器时发的令牌，回调带着它：同一个 id 删了又加之后，旧连接器迟到的健康回报据此丢掉。
    private var tokens: [String: UUID] = [:]
    private var specs: [String: AcpAgentSpec] = [:]
    private var health: [String: Health] = [:]
    /// 握手成功过的 agent（报过 ok 或 degraded，或者经反向扩展连进来过）。之后的拉起失败照常报 `error`，不再隐藏。
    private var verified: Set<String> = []
    /// 第一次握手就失败的注册表 agent：不进注册表条目，`isActive` 为 false（不接命令、不对账、不刷新列表、
    /// 不因开关变化去停）。
    private var unverified: Set<String> = []
    private var lastListRefresh: [String: Date] = [:]
    private var refreshTask: Task<Void, Never>?
    /// 每次对账开始加一；收集完发现不是最新的就不写（见 `reconcile()`）。
    private var reconcileGeneration = 0
    /// 反向连接 id → 它握手时报的 agent 与能力。
    private var reverseLinks: [UUID: ReverseLinkInfo] = [:]
    /// 上次看到时用户开着的 agent：`applyEnabledState()` 据此认出"刚启用"的，立刻刷一次列表。
    private var lastEnabled: Set<String> = []
    /// App 正在退出（`shutdown()`）：命令一律失败，发现、刷新、反向握手都不再做。不可逆。
    private var isShutDown = false

    public init(store: TaskStore, makeConnector: @escaping ConnectorFactory) {
        self.store = store
        self.makeConnector = makeConnector
    }

    // MARK: - 发现结果

    /// 换一批发现结果：新来的建连接器，消失的停掉，配置变了的更新。然后同步注册表并对账。
    ///
    /// 第一个 `await` 之前就把 hub 自己的状态改完：两次 `sync` 交错时，后进来的一次看到的是前一次改完的样子，
    /// 不会把连接器建两遍，也不会让前一次的 `specs` 盖掉后一次的。
    public func sync(_ agents: [AcpAgentSpec]) async {
        guard !isShutDown else { return }
        let incoming = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var removed: [AcpConnector] = []
        for (id, connector) in connectors where incoming[id] == nil {
            removed.append(connector)
            forget(id)
        }
        var changed: [String] = []
        var created: [String] = []
        for (id, spec) in incoming {
            guard let old = specs[id], connectors[id] != nil else {
                create(spec)
                created.append(id)
                continue
            }
            guard old != spec else { continue }
            changed.append(id)
            // 发现结果变了：重新给一次握手的机会。
            unverified.remove(id)
            if Self.launchChanged(old, spec) {
                // 换了启动方式：旧的错误、旧的验证、刷新时间都不作数了。
                verified.remove(id)
                health.removeValue(forKey: id)
                lastListRefresh.removeValue(forKey: id)
            }
        }
        specs = incoming
        // 条目写进注册表之后才查得到开关。新来的按当前开关记下，之后翻开关时才认得出"刚启用"。
        let entriesChanged = writeEntries()
        for id in created where store.connectors.isAcpEnabled(id) { lastEnabled.insert(id) }
        if entriesChanged { _ = await store.broadcastSnapshot() }
        for connector in removed { await connector.stop() }
        for id in changed {
            // 取此刻的配置而不是上面记下的：两次 sync 交错时，前一次迟到的 update 不能把后一次的配置盖回去。
            guard let connector = connectors[id], let spec = specs[id] else { continue }
            await connector.update(spec: spec)
        }
        await reconcile()
    }

    /// 用户开关变了（本机或手机）：停用的 agent 关掉进程、断开反向连接，然后按新的开关重新对账
    /// （`.acp` 的项目列表只能在这里按"已启用的 agent"重算）。
    ///
    /// 刚启用的 agent（没被藏起来的）立刻刷一次 `session/list`，不等下一轮刷新（最长 `listInterval`，
    /// 没在跑的甚至 `idleListInterval`）。刷新放到后台，不拖住调用方。
    public func applyEnabledState() async {
        guard !isShutDown else { return }
        let enabled = Set(connectors.keys.filter { store.connectors.isAcpEnabled($0) })
        let newlyEnabled = enabled.subtracting(lastEnabled)
        lastEnabled = enabled
        for (id, connector) in connectors where !store.connectors.isAcpEnabled(id) && !unverified.contains(id) {
            await connector.stop()
        }
        await reconcile()
        let now = Date()
        for id in newlyEnabled.sorted() {
            // 上面的 await 期间可能已经退出、被删、又被停用或藏起来了。
            guard !isShutDown, let connector = connectors[id], isActive(id) else { continue }
            lastListRefresh[id] = now
            Task { await connector.refreshList() }
        }
    }

    /// 停掉全部连接器与列表刷新。之后还能 `startRefreshing()`（测试收尾用）；退出用 `shutdown()`。
    public func stop() async {
        refreshTask?.cancel()
        refreshTask = nil
        for connector in connectors.values { await connector.stop() }
    }

    /// 解除配对或被接管：只关子进程（在跑的轮次记 interrupted、交还所有权），反向连接与它报的会话留着，
    /// 列表刷新照旧——观察不依赖配对。
    public func stopSubprocesses() async {
        guard !isShutDown else { return }
        for connector in connectors.values { await connector.stopSubprocess() }
    }

    /// App 退出（在释放实例锁之前）：不可逆。之后命令与 `checkAvailable` 失败（"BotBus 正在退出"），
    /// `sync`、`applyEnabledState`、列表刷新、反向握手都不再做；连接器全部 `shutdown()`，
    /// 已经在途、稍后才走到拉起的那一步的命令或刷新也起不来。
    public func shutdown() async {
        isShutDown = true
        refreshTask?.cancel()
        refreshTask = nil
        for connector in connectors.values { await connector.shutdown() }
    }

    // MARK: - 对账与刷新

    /// 把已启用 agent 的任务合起来对账 `.acp` 这个来源。
    ///
    /// 收集要逐个 await 连接器，期间可能又有一次对账开始（列表刷新完、一轮结束几乎同时到）。这时只让后开始的那次写：
    /// 它开始得晚，触发它的变化都已经在它读到的结果里；先开始的若最后才写，会把刚列出来的会话又摘掉。
    ///
    /// **通知基线按 agent 走**：同时告诉 store 哪些 agent 的列表基线已就绪（`AcpConnector.isListBaselined`）。
    /// 没就绪的（比如重启后只有本机记录、第一次 `session/list` 还没回来）这一轮全静默；刚就绪的由 store 再静默一轮。
    /// 每个连接器**先读基线再取任务**：两次 await 之间列表若刚好刷完，最多是多静默一轮，不会漏掉基线。
    public func reconcile() async {
        reconcileGeneration += 1
        let generation = reconcileGeneration
        var tasks: [TaskRecord] = []
        var baselined: Set<String> = []
        for (id, connector) in connectors where isActive(id) {
            if await connector.isListBaselined { baselined.insert(id) }
            tasks += await connector.staticTasks()
        }
        let agentId = await store.identity.agentId
        guard generation == reconcileGeneration else { return }
        _ = await store.reconcileAcp(tasks: tasks, projects: SessionFormatting.projects(from: tasks, agentId: agentId),
                                     baselined: baselined)
    }

    /// 周期刷新 `session/list`：进程在跑的每 `listInterval` 刷一次；没在跑的每 `idleListInterval` 才拉起一次。
    /// 第一轮立刻开始，注册表 agent 的第一次握手（验证）通常就发生在这里。
    public func startRefreshing() {
        guard refreshTask == nil, !isShutDown else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLocalSessions()
                await self?.refreshLists(now: Date())
                guard self != nil else { return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    public func refreshLocalSessions() async {
        guard !isShutDown else { return }
        for (id, connector) in connectors where isActive(id) {
            await connector.refreshLocalSessions()
        }
    }

    func refreshLists(now: Date) async {
        guard !isShutDown else { return }
        var due: [AcpConnector] = []
        for (id, connector) in connectors where isActive(id) {
            let running = await connector.isRunning
            let last = lastListRefresh[id] ?? .distantPast
            let interval = running ? Self.listInterval : Self.idleListInterval
            guard now.timeIntervalSince(last) >= interval else { continue }
            // 上面的 await 期间这个 agent 可能已经被删掉、换掉、停用、藏起来，或者 app 开始退出了。
            guard !isShutDown, connectors[id] === connector, isActive(id) else { continue }
            lastListRefresh[id] = now
            due.append(connector)
        }
        guard !isShutDown else { return }
        // 各 agent 并行刷：一个起得慢的（握手最多等 10 秒、列表每页最多 60 秒）不拖累别的。
        await withTaskGroup(of: Void.self) { group in
            for connector in due { group.addTask { await connector.refreshList() } }
        }
    }

    // MARK: - TaskConnector / MessageReader

    public func start(projectPath: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        throw ConnectorError("缺少 connectorId：ACP 任务要指明发给哪个 agent")
    }

    /// 分发器在建新项目文件夹、下载图之前先问：agent 在不在、开没开、能不能从手机新建任务。
    /// 收不收图要握手后才知道，这里不管。
    public func checkAvailable(connectorId: String) async throws {
        _ = try connector(connectorId)
        guard let spec = specs[connectorId], canStartTask(spec) else {
            throw ConnectorError("这个 Agent 只能在电脑上发起任务")
        }
    }

    public func start(connectorId: String, projectPath: String, prompt: String,
                      images: [URL]) async throws -> ConnectorOutcome {
        try await connector(connectorId).start(projectPath: projectPath, prompt: prompt, images: images)
    }

    public func followUp(taskId: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        try await connector(forTask: taskId).followUp(taskId: taskId, prompt: prompt, images: images)
    }

    public func approve(taskId: String, requestId: String,
                        decision: Command.Approve.Decision) async throws -> ConnectorOutcome {
        try await connector(forTask: taskId).approve(taskId: taskId, requestId: requestId, decision: decision)
    }

    public func approve(taskId: String, requestId: String, decision: Command.Approve.Decision,
                        answers: [String: [String]]?) async throws -> ConnectorOutcome {
        try await connector(forTask: taskId).approve(taskId: taskId, requestId: requestId, decision: decision,
                                                     answers: answers)
    }

    public func interrupt(taskId: String) async throws -> ConnectorOutcome {
        try await connector(forTask: taskId).interrupt(taskId: taskId)
    }

    public func entries(taskId: String, limit: Int) async throws -> (entries: [TranscriptEntry], hasMore: Bool) {
        try await connector(forTask: taskId).entries(taskId: taskId, limit: limit)
    }

    // MARK: - 反向扩展（`AcpReverseServer` 调）

    public func acceptReverse(_ link: UUID, hello params: JSONValue, peer: JSONRPCPeer,
                              close: @escaping @Sendable () -> Void) async throws -> JSONValue {
        guard let hello = AcpHello(params: params) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "_botbus/hello 缺少 id 或 version")
        }
        guard hello.version == AcpReverseServer.extensionVersion else {
            return AcpHello.rejection("BotBus 只支持扩展版本 \(AcpReverseServer.extensionVersion)")
        }
        // 一条连接只握一次手：再来一次就是 agent 写错了，不能让它换个 id 冒充另一个 agent。
        guard reverseLinks[link] == nil else { return AcpHello.rejection("这条连接已经握过手了") }
        guard !isShutDown else { return AcpHello.rejection("BotBus 正在退出") }
        guard let connector = connectors[hello.id] else {
            return AcpHello.rejection("BotBus 没有发现 id 为 \(hello.id) 的 agent（清单放进 ~/.botbus/agents/ 了吗？）")
        }
        // 能按扩展协议握手的就是真的 ACP agent：算验证通过，藏起来的也放回来——要先写回注册表条目，
        // 下面才查得到它的开关。到 `reverseLinks` 记好之前都不 await，免得中途状态被别的调用改掉。
        verified.insert(hello.id)
        var changed = unverified.remove(hello.id) != nil && writeEntries()
        // 注册表条目有容量上限，排不上的不在条目里，`isAcpEnabled` 也是 false——那不是用户停用的，要说实话。
        guard store.connectors.acpIds.contains(hello.id) else {
            if changed { _ = await store.broadcastSnapshot() }
            return AcpHello.rejection("BotBus 最多同时接入 \(store.connectors.acpCapacity) 个 ACP agent，这个没排上")
        }
        guard store.connectors.isAcpEnabled(hello.id) else {
            if changed { _ = await store.broadcastSnapshot() }
            return AcpHello.rejection("用户在 BotBus 里停用了这个 agent")
        }
        // 先记下再 await：握手一过，这条连接上的请求就可能到。能力也记在 hub，写条目不必去问连接器。
        reverseLinks[link] = ReverseLinkInfo(agentId: hello.id, capabilities: hello.capabilities)
        changed = writeEntries() || changed
        await connector.attach(link, capabilities: hello.capabilities, peer: peer, close: close)
        // 挂上的这段时间里连接可能已经断了（`reverseClosed` 可能跑在 `attach` 之前，那次 detach 什么都没摘到），
        // agent 也可能被删掉或停用了（连接器的 `stop()` 可能跑在 `attach` 之前）。刚挂上的连接要再摘一次并断开，
        // 不能留在一个不再管它的连接器上。
        guard reverseLinks[link] != nil, connectors[hello.id] === connector,
              store.connectors.isAcpEnabled(hello.id) else {
            reverseLinks.removeValue(forKey: link)
            await connector.detach(link)
            close()
            if writeEntries() || changed { _ = await store.broadcastSnapshot() }
            return AcpHello.rejection("这个 agent 已被停用或移除")
        }
        if changed { _ = await store.broadcastSnapshot() }
        return ["accepted": true]
    }

    public func reverseRequest(_ link: UUID, _ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let id = reverseLinks[link]?.agentId, let connector = connectors[id] else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "请先发 _botbus/hello")
        }
        return try await connector.handleAgentRequest(method, params, link: link)
    }

    public func reverseNotification(_ link: UUID, _ method: String, _ params: JSONValue) async {
        guard let id = reverseLinks[link]?.agentId, let connector = connectors[id] else { return }
        await connector.handleAgentNotification(method, params, link: link)
    }

    public func reverseClosed(_ link: UUID) async {
        guard let id = reverseLinks.removeValue(forKey: link)?.agentId, let connector = connectors[id] else { return }
        await publishEntries()
        await connector.detach(link)
    }

    // MARK: - 内部

    private func create(_ spec: AcpAgentSpec) {
        let token = UUID()
        tokens[spec.id] = token
        connectors[spec.id] = makeConnector(spec, { [weak self] id, status, message, handshakeFailed in
            await self?.reportHealth(id, token: token, status, message, handshakeFailed: handshakeFailed)
        }, { [weak self] in
            await self?.reconcile()
        })
    }

    /// 一个 agent 从发现结果里消失：它的记账全清掉（反向连接由连接器的 `stop()` 去关）。
    private func forget(_ id: String) {
        connectors.removeValue(forKey: id)
        lastEnabled.remove(id)
        tokens.removeValue(forKey: id)
        health.removeValue(forKey: id)
        verified.remove(id)
        unverified.remove(id)
        lastListRefresh.removeValue(forKey: id)
        reverseLinks = reverseLinks.filter { $0.value.agentId != id }
    }

    private func reportHealth(_ id: String, token: UUID, _ status: ConnectorInfo.Status, _ message: String?,
                              handshakeFailed: Bool) async {
        guard tokens[id] == token, let spec = specs[id] else { return }
        if handshakeFailed, spec.origin == .registry, !verified.contains(id) {
            guard unverified.insert(id).inserted else { return }
            health.removeValue(forKey: id)
            // 失败原因可能带 stderr，只给界面看，不进日志。
            Self.log.notice("acp registry agent \(id, privacy: .public) failed its first handshake; hidden")
            await publishEntries()
            await reconcile()
            return
        }
        if status != .error {
            // 握上手了：确实是 ACP agent。
            verified.insert(id)
            unverified.remove(id)
        }
        health[id] = Health(status: status, message: message)
        await publishEntries()
    }

    /// 按 hub 自己的记账整批写注册表，变了就补一份全量快照。
    private func publishEntries() async {
        if writeEntries() { _ = await store.broadcastSnapshot() }
    }

    /// 整批写注册表条目，返回是否有变化。同步、不 await 连接器：不然两次发布交错时，先算好的旧结果会后写、盖掉新的。
    private func writeEntries() -> Bool {
        let entries = specs.values.filter { !unverified.contains($0.id) }.map { spec in
            let current = health[spec.id]
            return ConnectorRegistry.AcpEntry(id: spec.id, displayName: spec.name,
                                              defaultEnabled: spec.defaultEnabled, canStartTask: canStartTask(spec),
                                              status: current?.status ?? .ok, lastError: current?.message)
        }
        return store.connectors.setAcpEntries(entries)
    }

    /// 能不能从手机新建任务：有启动命令，或者有声明了 `newSession` 的反向连接（与 `AcpConnector.start` 的分支一致）。
    private func canStartTask(_ spec: AcpAgentSpec) -> Bool {
        spec.executable != nil
            || reverseLinks.values.contains { $0.agentId == spec.id && $0.capabilities.newSession }
    }

    /// 这个 agent 此刻算不算在用：没被藏起来，且用户没停用它。
    private func isActive(_ id: String) -> Bool {
        !unverified.contains(id) && store.connectors.isAcpEnabled(id)
    }

    private func connector(_ id: String) throws -> AcpConnector {
        guard !isShutDown else { throw ConnectorError("BotBus 正在退出") }
        guard let connector = connectors[id], !unverified.contains(id) else {
            throw ConnectorError("本机没有这个 ACP agent：\(id)")
        }
        guard store.connectors.isAcpEnabled(id) else { throw ConnectorError("\(specs[id]?.name ?? id) 已停用") }
        return connector
    }

    private func connector(forTask taskId: String) throws -> AcpConnector {
        guard let parsed = AcpTaskID.parse(taskId) else { throw ConnectorError("无法识别的任务 id：\(taskId)") }
        return try connector(parsed.connectorId)
    }

    private static func launchChanged(_ old: AcpAgentSpec, _ new: AcpAgentSpec) -> Bool {
        old.executable != new.executable || old.arguments != new.arguments || old.environment != new.environment
    }
}
