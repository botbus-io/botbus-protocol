import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 反向扩展（spec「反向扩展」）：agent 自己的进程连进来，实时报它的会话。
/// 有反向连接在报的会话由这条连接驱动，BotBus 绝不再对它拉子进程做 `session/load`
/// （`load()` 前后都查 `reverseOwner`，接管了就抛 `TakenOverByReverse`）。
///
/// 反向连接没有 `session/prompt` 的应答可等（终端里开的轮次 BotBus 看不到 prompt），轮次开始与结束靠
/// `_botbus/turn` 报。BotBus 自己经这条连接发的 prompt 另记在 `reverseTurns`：应答先到还是 `_botbus/turn ended`
/// 先到，都只收一次尾。
extension AcpConnector {
    /// 一条反向连接最多报这么多个会话，再报的忽略（同一用户下的进程能连进来，但不能无限往手机上推任务）。
    static let maxSessionsPerLink = 50

    /// hub 在 `_botbus/hello` 通过后挂上。连接断开时 hub 调 `detach`；`stop()` 自己交还并关连接。
    func attach(_ link: UUID, capabilities: AcpHello.Capabilities, peer: JSONRPCPeer,
                close: @escaping @Sendable () -> Void) async {
        links[link] = ReverseLink(peer: peer, capabilities: capabilities, close: close)
    }

    /// 连接断开：交还它报过的会话，然后请 hub 对账（`controllable` 可能变了）。
    func detach(_ link: UUID) async {
        guard await releaseReverse(link) else { return }
        await onTasksChanged()
    }

    /// 摘掉一条反向连接并交还它报过的会话：还在跑的一轮记成 interrupted（免得手机上永远"运行中"），
    /// 挂着的审批当取消，所有权走 `release`（带延迟补放）。返回这条连接之前是否挂着。
    ///
    /// 状态先一口气改完再 await：期间同一个会话若被另一条连接接管，它自己写状态、拿所有权，这里既不能盖掉它
    /// 写的记录，也不能替它放所有权。
    @discardableResult
    func releaseReverse(_ link: UUID) async -> Bool {
        guard links.removeValue(forKey: link) != nil else { return false }
        let timestamp = stamp()
        var released: [String] = []
        for (sessionId, owner) in reverseOwner where owner == link {
            reverseOwner.removeValue(forKey: sessionId)
            reverseTurns.removeValue(forKey: sessionId)
            resolvedElsewhere.removeValue(forKey: sessionId)
            _ = waiters.removeValue(forKey: sessionId)?.resume(returning: .cancelled)
            guard var state = sessions[sessionId] else { continue }
            if state.running {
                state.endTurn(.cancelled, error: nil, at: timestamp)
            } else {
                state.clearPending(at: timestamp)
            }
            // 连接一断就不能再经它续聊了：此刻能不能续聊看子进程那边（在不在进程里、支不支持 `session/load`）。
            state.record.controllable = controllable(sessionId, otherwise: false)
            sessions[sessionId] = state
            released.append(sessionId)
        }
        for sessionId in released {
            guard reverseOwner[sessionId] == nil, let record = sessions[sessionId]?.record else { continue }
            if record.origin == .watch { await archive.remember(connectorId: id, record: record) }
            await store.upsert(record)
            await release(record.id, sessionId: sessionId)
        }
        // 交还之后这些会话的对话记录可以按上限淘汰了。
        if let first = released.first { trimTranscripts(keeping: first) }
        return true
    }

    /// 反向连接发来的 `_botbus/*` 通知（`session/update` 由 `handleAgentNotification` 处理）。
    /// 由 `JSONRPCPeer` 的读循环串行调用：这里不能对同一个 peer 发请求并等应答。
    func handleReverseNotification(_ method: String, _ params: JSONValue, link: UUID) async {
        guard let sessionId = params["sessionId"]?.stringValue, !sessionId.isEmpty else { return }
        switch method {
        case "_botbus/session":
            await announce(sessionId, params: params, link: link)
        case "_botbus/turn":
            if reportTurn(sessionId, params: params, link: link) { await publish(sessionId) }
        case "_botbus/permission_resolved":
            guard reverseOwner[sessionId] == link, let toolCallId = params["toolCallId"]?.stringValue else { return }
            // 先记下：审批请求可能还在路上（请求与通知不走同一条串行路径），`askPhone` 据此不再挂上去。
            resolvedElsewhere[sessionId] = toolCallId
            guard var state = sessions[sessionId], state.pending?.toolCall.toolCallId == toolCallId,
                  let box = waiters.removeValue(forKey: sessionId) else { return }
            state.clearPending(at: stamp())
            sessions[sessionId] = state
            // 同 `approve`：先写"回到运行中"再回应 agent。
            await store.upsert(state.record)
            _ = box.resume(returning: .unanswered)
        default:
            return
        }
    }

    /// `_botbus/session`：从此把这个会话当作实时任务。子进程正在跑它的一轮、或者另一条还活着的连接在报它时不接管。
    ///
    /// 子进程那边"载入完、还没发 prompt"的空当不在这里拦：`commitTurn` 在发 prompt 前同步复查接管，被接管就改走反向连接。
    private func announce(_ sessionId: String, params: JSONValue, link: UUID) async {
        guard links[link] != nil, let cwd = params["cwd"]?.stringValue, !cwd.isEmpty, turns[sessionId] == nil else { return }
        // agent 断线马上重连、重报同一个会话时，旧连接的 `detach` 可能还没轮到：旧连接的 peer 已经关了（读循环先关 peer
        // 再通知 hub），就先替它交还，免得新连接报的会话被当成冒领丢掉。
        if let owner = reverseOwner[sessionId], owner != link {
            guard let other = links[owner], await other.peer.isClosed else {
                Self.log.notice("acp reverse link tried to claim a session owned by another live link; ignored")
                return
            }
            await releaseReverse(owner)
        }
        guard reverseOwner[sessionId] == link || ownedCount(link) < Self.maxSessionsPerLink else {
            Self.log.notice("acp reverse link \(link, privacy: .public) reached \(Self.maxSessionsPerLink) sessions; ignored")
            return
        }
        let taskId = identity.taskId(sessionId: sessionId)
        // 内存里没有就沿用 store 里的（列表、本机记录报过的）：标题、来源、开始时间都留着；还挂着"运行中"的旧记录
        // 按本机记录的规矩当被中断（真在跑的话 agent 随后会报 `_botbus/turn started`）。
        let known = sessions[sessionId] == nil ? try? await knownState(sessionId, taskId: taskId) : nil
        // 上面的 await 期间：连接可能断了，别的连接可能接管了，子进程可能开了一轮。
        guard let capabilities = links[link]?.capabilities, reverseOwner[sessionId] ?? link == link,
              turns[sessionId] == nil,
              reverseOwner[sessionId] == link || ownedCount(link) < Self.maxSessionsPerLink else { return }
        let adopted = known.map { known -> AcpSessionState in
            var copy = known
            copy.record = Self.aged(known.record, now: now())
            return copy
        }
        let title = params["title"]?.stringValue
        var state = sessions[sessionId] ?? adopted ?? AcpSessionState(record: AcpSessionState.newRecord(
            identity: identity, sessionId: sessionId, cwd: cwd, title: title, origin: .desktop,
            controllable: false, at: stamp()))
        if let title { state.apply(.sessionInfo(title: title), at: stamp()) }
        state.record.controllable = capabilities.prompt
        reverseOwner[sessionId] = link
        // 子进程里就算载入过也作废：之后一律走反向连接。
        loaded.remove(sessionId)
        sessions[sessionId] = state
        trimTranscripts(keeping: sessionId)
        await store.claimLive(taskId, ownerToken: liveOwnerToken)
        await store.upsert(sessions[sessionId]?.record ?? state.record)
    }

    /// `_botbus/turn`。`started` 时已经在跑（BotBus 刚经这条连接发了 prompt）就不另起一轮，
    /// 这一轮记过的 prompt 与回显判断都留着。
    /// 返回状态是否变了。挂着的审批 BotBus 没有答案了（`unanswered`：agent 继续等终端）。
    private func reportTurn(_ sessionId: String, params: JSONValue, link: UUID) -> Bool {
        guard reverseOwner[sessionId] == link, var state = sessions[sessionId] else { return false }
        switch params["state"]?.stringValue {
        case "started":
            guard !state.running else { return false }
            _ = waiters.removeValue(forKey: sessionId)?.resume(returning: .unanswered)
            reverseTurns.removeValue(forKey: sessionId)
            state.beginTurn(prompt: "", images: [], at: stamp())
        case "ended":
            reverseTurns.removeValue(forKey: sessionId)
            _ = waiters.removeValue(forKey: sessionId)?.resume(returning: .unanswered)
            if state.running {
                state.endTurn(params["stopReason"]?.stringValue.flatMap(AcpStopReason.init(rawValue:)),
                              error: nil, at: stamp())
            } else {
                state.clearPending(at: stamp())
            }
        default:
            return false
        }
        sessions[sessionId] = state
        return true
    }

    /// 把会话此刻的记录写进 store（BotBus 拉起的另记一份到本机）。
    private func publish(_ sessionId: String) async {
        guard let record = sessions[sessionId]?.record else { return }
        await store.upsert(record)
        if record.origin == .watch { await archive.remember(connectorId: id, record: record) }
    }

    func followUpOverReverse(_ sessionId: String, taskId: String, prompt: String,
                             images: [URL]) async throws -> ConnectorOutcome {
        // 找不到连接只会发生在测试里直接改 `reverseOwner` 时；照"没声明 prompt"处理。
        guard let owner = reverseOwner[sessionId], let link = links[owner], link.capabilities.prompt else {
            throw ConnectorError("这个会话正在电脑上运行，请在电脑上继续")
        }
        guard images.isEmpty else { throw ConnectorError("这个 Agent 暂不支持发图") }
        guard !prompt.isEmpty else { throw ConnectorError("消息不能为空") }
        guard var state = sessions[sessionId], !state.running else {
            throw ConnectorError("这个会话正在运行，等它这一轮结束再续聊")
        }
        state.beginTurn(prompt: prompt, images: [], at: stamp())
        sessions[sessionId] = state
        let turn = UUID()
        reverseTurns[sessionId] = turn
        await publish(sessionId)
        // 上面的 await 期间连接断了（`releaseReverse` 已把这一轮记成 interrupted）：消息没发出去，如实报错。
        guard reverseOwner[sessionId] == owner, reverseTurns[sessionId] == turn else {
            throw ConnectorError("电脑上的连接已断开，这条消息没有发出去")
        }
        sendPrompt(prompt, sessionId: sessionId, turn: turn, over: link.peer)
        return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: true)
    }

    func interruptOverReverse(_ sessionId: String, taskId: String) async throws -> ConnectorOutcome {
        guard let owner = reverseOwner[sessionId], let link = links[owner], link.capabilities.cancel else {
            throw ConnectorError("这个会话正在电脑上运行，只能在电脑上中断")
        }
        // ACP 要求：发 `session/cancel` 时挂着的审批一律回 cancelled。同 `interrupt`，先写状态再放行。
        if let box = waiters.removeValue(forKey: sessionId) {
            if var state = sessions[sessionId] {
                state.clearPending(at: stamp())
                sessions[sessionId] = state
                await store.upsert(state.record)
            }
            _ = box.resume(returning: .cancelled)
        }
        await link.peer.notify("session/cancel", params: ["sessionId": .string(sessionId)])
        // 这一轮由 agent 报的 `_botbus/turn ended`（或 prompt 的应答）收尾；所有权跟着连接走。
        return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: true)
    }

    /// 经反向连接新建（spec「命令对应」）：常驻型 agent 的清单可以不写 command，靠声明了 `newSession` 的连接。
    func startOverReverse(projectPath: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        guard let pair = links.first(where: { $0.value.capabilities.newSession }) else {
            throw ConnectorError("\(spec.name) 没有配置启动命令，也没有在电脑上运行，没法从手机新建任务")
        }
        let (owner, link) = (pair.key, pair.value)
        guard images.isEmpty else { throw ConnectorError("这个 Agent 暂不支持发图") }
        guard !prompt.isEmpty else { throw ConnectorError("消息不能为空") }
        let injection = await AgentToolsInjection.make(tools(), registry: registry)
        let sessionId: String
        do {
            sessionId = try await AcpClient(peer: link.peer)
                .newSession(cwd: projectPath, mcpServers: injection.map { [.botbus($0)] } ?? [])
        } catch {
            throw await failure(error)
        }
        // `session/new` 期间连接可能断了；agent 也可能先用 `_botbus/session` 报了这个会话（那就接着用它的状态）。
        guard links[owner] != nil else { throw ConnectorError("电脑上的连接已断开，没能新建任务") }
        guard reverseOwner[sessionId] ?? owner == owner, turns[sessionId] == nil else {
            throw ConnectorError("agent 返回的会话 \(sessionId) 已由另一条连接或 BotBus 自己在驱动，没能新建任务")
        }
        let timestamp = stamp()
        var state = sessions[sessionId] ?? AcpSessionState(record: AcpSessionState.newRecord(
            identity: identity, sessionId: sessionId, cwd: projectPath, title: nil, origin: .watch,
            controllable: link.capabilities.prompt, at: timestamp))
        state.record.origin = .watch
        state.record.controllable = link.capabilities.prompt
        let taskId = state.record.id
        state.beginTurn(prompt: prompt, images: [], at: timestamp)
        reverseOwner[sessionId] = owner
        loaded.remove(sessionId)
        let turn = UUID()
        reverseTurns[sessionId] = turn
        sessions[sessionId] = state
        trimTranscripts(keeping: sessionId)
        if let injection { await registry.bind(injection.token, taskId: taskId) }
        // 先写 running 再发 prompt：反过来的话，一轮若很快结束，收尾写的最终状态会被这里的 running 盖掉。
        await store.claimLive(taskId, ownerToken: liveOwnerToken)
        await publish(sessionId)
        guard reverseOwner[sessionId] == owner, reverseTurns[sessionId] == turn else {
            throw ConnectorError("电脑上的连接已断开，没能新建任务")
        }
        sendPrompt(prompt, sessionId: sessionId, turn: turn, over: link.peer)
        return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: true)
    }

    /// 这条连接此刻报着几个会话。
    private func ownedCount(_ link: UUID) -> Int {
        reverseOwner.values.reduce(0) { $0 + ($1 == link ? 1 : 0) }
    }

    /// 反向连接上发 prompt 不在命令里等它：agent 会报 `_botbus/turn`；它若回了 stopReason 也照收（只收一次）。
    /// 连接断开时 peer 关闭，请求带着 closed 失败，那时 `releaseReverse` 早已收过尾，这里什么都不做。
    private func sendPrompt(_ prompt: String, sessionId: String, turn: UUID, over peer: JSONRPCPeer) {
        let client = AcpClient(peer: peer)
        Task { [weak self] in
            let outcome: Result<AcpStopReason, Error>
            do {
                outcome = .success(try await client.prompt(sessionId, text: prompt, images: []))
            } catch {
                outcome = .failure(error)
            }
            await self?.reversePromptFinished(sessionId, turn: turn, outcome: outcome)
        }
    }

    private func reversePromptFinished(_ sessionId: String, turn: UUID, outcome: Result<AcpStopReason, Error>) async {
        guard reverseTurns[sessionId] == turn else { return }
        reverseTurns.removeValue(forKey: sessionId)
        guard reverseOwner[sessionId] != nil, var state = sessions[sessionId], state.running else { return }
        _ = waiters.removeValue(forKey: sessionId)?.resume(returning: .unanswered)
        switch outcome {
        case .success(let stop): state.endTurn(stop, error: nil, at: stamp())
        case .failure(let error): state.endTurn(nil, error: Self.describe(error), at: stamp())
        }
        sessions[sessionId] = state
        await publish(sessionId)
    }
}
