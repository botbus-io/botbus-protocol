import Foundation
import os
import BotBusProtocol

/// 客户端命令的唯一入口：去重、校验目标电脑、按 id 前缀路由到连接器、把一切错误收敛成
/// `CommandResult{ok:false}`。`RelayClient` 的 `commandHandler` 直接指向它的 `handle(_:)`。
///
/// 几条不显然的约定：
///
/// - **去重是必须的，不是优化**。Relay 明确不按 id 去重（`PROTOCOL.md` 的连接语义一节），
///   客户端重试会原样重发同一个 `command.id`。重复到达时不重新执行，而是把第一次的结果再回一遍：
///   客户端之所以重试，多半正是因为上一份回执没送达（`commandResult` 至多送达一次），
///   给它一条"重复"错误只会让用户看到一次并不存在的失败。
/// - **结果与事件之间没有顺序保证**。`commandResult` 和命令引起的 `taskUpdated` 是两次独立的发送，
///   断线重连时 outbox 还会改变它们的相对次序。所以回执必须自带足够信息：只要知道 taskId，
///   连失败的回执也填上，客户端不能依赖"先看到任务再看到结果"。
/// - **所有权按命令的生命周期认领**。命令执行期间对应 id 归 `.live`，只读观察不得改写；
///   结束后交还，除非连接器在 `ConnectorOutcome` 里声明轮次还在跑（`retainsLiveOwnership`）。
public actor CommandDispatcher {
    /// 记得多少条已处理的命令 id。够大到覆盖任何合理的重试窗口（客户端的离线队列上限是 50），
    /// 又不至于无限长。
    public static let maxRememberedCommands = 200
    /// `CommandResult.error` 的截断长度。协议没规定上限，但没人要看一屏子进程日志。
    public static let errorLimit = 200

    private static let log = Logger(subsystem: "io.botbus.agent", category: "dispatcher")

    /// 内部失败。带上已知的 taskId，失败的回执也能被客户端对上号。
    private struct DispatchFailure: Error {
        let message: String
        let taskId: String?
        init(_ message: String, taskId: String? = nil) {
            self.message = message
            self.taskId = taskId
        }
    }

    /// 去重表里的一条。存的是执行中的 `Task` 而不是结果：重复命令统一 `await` 它的值——
    /// 已经跑完就立刻拿到，还在跑就等着，两条路径出同一个结果，也就不存在"跑到一半又被起一次"。
    private struct Entry {
        let task: Task<CommandResult, Never>
        var finished: Bool
    }

    private let store: TaskStore
    private let now: @Sendable () -> Date
    private var connectors: [ConnectorKind: any TaskConnector]
    /// 读对话记录的来源。和连接器分开存，因为它在连接器没跑的时候也要能用
    /// （Codex 的 SQLite、Claude 的 transcript 文件都不依赖子进程）。
    private var readers: [ConnectorKind: any MessageReader]
    /// 对话里图片的上传与去重（协议 2.9）。nil = 不带附件，行为与 2.9 之前一致（测试默认）。
    private let attachments: (any MessageAttachmentResolving)?
    /// 手机随 `startTask` / `followUp` 发来的图（协议 2.9），调用连接器之前先下载到本机。
    /// nil = 本机收不了图，带附件的命令直接失败（测试默认）。
    private let inbox: (any AttachmentReceiving)?
    /// 手机按需取回 Agent 回复里提到的文件（协议 2.9 的 `fetchFile`），也用它的索引给文件卡片填 artifactId。
    /// nil = 卡片照样出、但一律不带 id，`fetchFile` 直接失败（测试默认）。
    private let files: (any FileFetching)?
    /// 手机看任务目录里没提交的改动（协议 2.11 的 `fetchChanges`）。nil = 一律失败（测试默认）。
    private let changes: (any WorkingChangesUploading)?
    private var remoteControl: (any RemoteControlling)?
    private var systemPermissionInspector: SystemPermissionInspector?
    private let systemPermissionInspectionTimeout: TimeInterval
    private var systemPermissionGeneration = 0
    private var entries: [String: Entry] = [:]
    /// 去重表的插入顺序，淘汰时从队首找。
    private var order: [String] = []

    public init(store: TaskStore,
                connectors: [any TaskConnector] = [],
                readers: [any MessageReader] = [],
                attachments: (any MessageAttachmentResolving)? = nil,
                inbox: (any AttachmentReceiving)? = nil,
                files: (any FileFetching)? = nil,
                changes: (any WorkingChangesUploading)? = nil,
                systemPermissionInspector: SystemPermissionInspector? = nil,
                systemPermissionInspectionTimeout: TimeInterval = 10,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.attachments = attachments
        self.inbox = inbox
        self.files = files
        self.changes = changes
        self.systemPermissionInspector = systemPermissionInspector
        self.systemPermissionInspectionTimeout = systemPermissionInspectionTimeout
        self.now = now
        var byKind: [ConnectorKind: any TaskConnector] = [:]
        for connector in connectors where byKind[connector.kind] == nil { byKind[connector.kind] = connector }
        self.connectors = byKind
        var readersByKind: [ConnectorKind: any MessageReader] = [:]
        for reader in readers where readersByKind[reader.kind] == nil { readersByKind[reader.kind] = reader }
        self.readers = readersByKind
    }

    /// 远程操作服务。它依赖预览分享，而预览分享在 AgentModel 里晚于分发器构造，所以走注入而不是 init 参数。
    public func setRemoteControl(_ service: (any RemoteControlling)?) {
        remoteControl = service
    }

    /// 注册（或替换）一个连接器。设置里换了 codex 二进制、或 Claude 的 hooks 装好之后重建连接器时用。
    public func register(_ connector: any TaskConnector) {
        connectors[connector.kind] = connector
    }

    /// During a desktop bridge handoff, stop routing new commands to a stopped process.
    public func unregister(_ kind: ConnectorKind) {
        connectors.removeValue(forKey: kind)
    }

    /// 注册（或替换）一个对话读取器。ACP 的 hub 在配对之后才建出来，不能只靠 init 里的那一批。
    public func register(reader: any MessageReader) {
        readers[reader.kind] = reader
    }

    /// 配对或设置改变时使在途诊断失效。命令的原始结果与按 id 去重继续照常工作。
    public func setSystemPermissionInspector(_ inspector: SystemPermissionInspector?) {
        systemPermissionGeneration += 1
        systemPermissionInspector = inspector
    }

    /// 去重表里当前记着多少条命令。可能短暂超过上限：还在执行的命令不许被挤掉。
    public var rememberedCommandCount: Int { entries.count }

    /// 执行一条命令并给出回执。永不抛错、永不崩溃：连接器抛什么都会变成 `ok:false`。
    public func handle(_ command: Command) async -> CommandResult {
        // 路由之前先认人。Relay 按 agentId 投递，但迟到的帧、离线队列与将来的 bug 都可能把别人的命令
        // 送到这里；未配对时 agentId 是空串，任何命令都不该被执行。
        let agentId = await store.identity.agentId
        guard command.agentId == agentId else {
            Self.log.warning("拒绝目标不是本机的命令：\(command.id, privacy: .public)")
            return CommandResult(commandId: command.id, ok: false, error: "命令的目标电脑不是本机",
                                 taskId: Self.targetTaskId(command), finishedAt: timestamp())
        }

        if let entry = entries[command.id] {
            Self.log.info("命令 \(command.id, privacy: .public) 重复到达，沿用第一次的结果")
            // 注意：这里 await 的可能是一条还在执行的命令，重复方会一直等到它出结果。
            // 这正是想要的——回执要么是真结果，要么什么都不是。
            return await entry.task.value
        }

        // 从这里到把 Entry 写进表之间没有挂起点，两条并发到达的同 id 命令不会双双开跑。
        let task = Task<CommandResult, Never> { [weak self] in
            guard let self else {
                return CommandResult(commandId: command.id, ok: false, error: "分发器已经停止",
                                     finishedAt: ProtocolJSON.timestamp())
            }
            let result = await self.execute(command)
            await self.markFinished(command.id)
            return result
        }
        entries[command.id] = Entry(task: task, finished: false)
        order.append(command.id)
        trim()
        return await task.value
    }

    // MARK: - 去重表

    private func markFinished(_ id: String) {
        entries[id]?.finished = true
        trim()
    }

    /// 超出上限时从最旧的开始淘汰，**跳过还在执行的**——把正在跑的命令从表里摘掉，
    /// 等于给它的重发开了第二次执行的口子。全表都在执行时就先超上限放着，命令一结束自会再修一次。
    private func trim() {
        var index = 0
        while entries.count > Self.maxRememberedCommands, index < order.count {
            let id = order[index]
            guard let entry = entries[id] else {
                order.remove(at: index)
                continue
            }
            guard entry.finished else {
                index += 1
                continue
            }
            entries.removeValue(forKey: id)
            order.remove(at: index)
        }
    }

    // MARK: - 执行

    private func execute(_ command: Command) async -> CommandResult {
        // setConnectorEnabled 不经连接器：开关与随之而来的全量快照都归 TaskStore。
        if command.kind == .setConnectorEnabled { return await store.handle(command).result }
        let inspectionGeneration = systemPermissionGeneration
        do {
            // fetchChanges 的回执要多带一个产物 id，单独走。
            if command.kind == .fetchChanges {
                guard let payload = command.fetchChanges else { throw DispatchFailure("缺少 fetchChanges 载荷") }
                let artifactId = try await fetchChanges(payload)
                return CommandResult(commandId: command.id, ok: true, taskId: payload.taskId, finishedAt: timestamp(),
                                     artifactId: artifactId)
            }
            // remoteControl 的回执要带预览产物 id，手机拿它直接打开远程画面。
            if command.kind == .remoteControl {
                guard let payload = command.remoteControl else { throw DispatchFailure("缺少 remoteControl 载荷") }
                guard let remoteControl else { throw DispatchFailure("这台电脑不支持远程操作") }
                guard payload.enabled else {
                    await remoteControl.stopSession()
                    return CommandResult(commandId: command.id, ok: true, finishedAt: timestamp())
                }
                let artifact = try await remoteControl.startSession()
                return CommandResult(commandId: command.id, ok: true, finishedAt: timestamp(),
                                     artifactId: artifact.id)
            }
            let taskId = try await run(command)
            return CommandResult(commandId: command.id, ok: true, taskId: taskId, finishedAt: timestamp())
        } catch {
            let failure = error as? DispatchFailure
            let message = failure?.message ?? Self.describe(error)
            if (error as? ConnectorError)?.containsPrivateDetail == true {
                // 例如 ACP agent 的 stderr：手机上照样看得到，日志里不公开。
                Self.log.error("命令 \(command.id, privacy: .public) 失败：\(message, privacy: .private)")
            } else {
                Self.log.error("命令 \(command.id, privacy: .public) 失败：\(message, privacy: .public)")
            }
            var result = CommandResult(commandId: command.id, ok: false, error: Self.truncate(message),
                                       taskId: failure?.taskId ?? Self.targetTaskId(command), finishedAt: timestamp())
            // 只在写入任务失败后检查；读历史/取文件、审批、中断及目标电脑错误都不触发。
            if (command.kind == .startTask || command.kind == .followUp), !(error is CancellationError),
               !Task.isCancelled, command.agentId == (await store.identity.agentId),
               inspectionGeneration == systemPermissionGeneration, let inspector = systemPermissionInspector {
                let notice = await inspectSystemPermission(using: inspector, timeout: systemPermissionInspectionTimeout)
                // 先 await 归属，再核代际；核对之后不能再挂起，否则设置变化可穿过检查。
                if command.agentId == (await store.identity.agentId),
                   inspectionGeneration == systemPermissionGeneration {
                    result.systemPermission = notice
                    if let notice {
                        await store.notifySystemPermission(notice, taskId: result.taskId, agentId: command.agentId)
                    }
                }
            }
            result.finishedAt = timestamp()
            return result
        }
    }

    /// 在 `TaskStore.projectsRoot` 下建新项目的文件夹，返回它的路径。
    ///
    /// 手机给的只是一个文件夹名：名字不合法（多层、`..`、隐藏目录）直接拒绝，目录只可能落在存放目录下面。
    /// 同名目录已经在了也拒绝，不复用——把 Agent 放进一个旧目录里比报错更糟，旧项目应当从项目列表里选。
    private func createProjectDirectory(named rawName: String) async throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Command.StartTask.isValidNewProjectName(name) else {
            throw DispatchFailure("项目名「\(name)」不能用：只能是一层文件夹名，不能含 / \\ :，也不能以 . 开头")
        }
        guard let root = await store.projectsRoot, !root.isEmpty else {
            throw DispatchFailure("这台电脑没有设置新项目的存放目录")
        }
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        let target = rootURL.appendingPathComponent(name, isDirectory: true)
        // 名字已经挡掉了 `/` 与 `..`，这里再按标准化路径核一遍：目录必须恰好是存放目录的直接子目录。
        guard target.standardizedFileURL.deletingLastPathComponent().path == rootURL.standardizedFileURL.path else {
            throw DispatchFailure("项目名「\(name)」不能用")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            throw DispatchFailure("「\(name)」已经存在了，请直接从项目列表里选它")
        }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            throw DispatchFailure("建不了项目文件夹：\(error.localizedDescription)")
        }
        return target.path
    }

    /// 成功时返回受影响的 taskId。抛出的一切由 `execute` 兜住。
    private func run(_ command: Command) async throws -> String? {
        switch command.kind {
        case .startTask:
            guard let payload = command.startTask else { throw DispatchFailure("缺少 startTask 载荷") }
            guard let kind = ConnectorKind(payload.source) else {
                throw DispatchFailure("未知的任务来源 \(payload.source.rawValue)")
            }
            let connector = try self.connector(for: kind)
            // 协议 2.13：ACP agent 共用一个 kind，新建任务要指明发给哪一个。这个 agent 可不可用也要在这里就问清：
            // 和下面的"先找连接器"同一个道理，停用、藏起来、不存在或没给 connectorId 时不能先建目录再失败。
            var target: (connector: any MultiAgentConnector, connectorId: String)?
            if kind == .acp {
                guard let connectorId = payload.connectorId, let multi = connector as? any MultiAgentConnector else {
                    throw DispatchFailure("ACP 任务缺少 connectorId")
                }
                try await multi.checkAvailable(connectorId: connectorId)
                target = (multi, connectorId)
            }
            // 协议 3.2：手机选了模型，这个 agent 却没报可选模型（ACP、Hermes 这些）——在下载图、建目录之前就拒掉。
            let selection = ModelSelection(payload)
            if !selection.isEmpty, target != nil || store.connectors.models(for: kind) == nil {
                throw DispatchFailure("这个 agent 不能从手机选模型")
            }
            // 先找连接器再下载：连接器停用、来源不收图时都不白下一趟图。下载也排在建新项目文件夹之前，
            // 图取不下来时不留空目录。
            let images = try await receiveImages(command, payload.attachments, kind: kind)
            var projectPath = payload.projectPath
            if let name = payload.newProject {
                // 协议 2.6：先在存放目录下建好新项目的文件夹，再在里面开始。连接器可用才建，免得留下空目录。
                projectPath = try await createProjectDirectory(named: name)
            } else if kind != .openclaw, projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 协议 2.6：空目录 = 「不在项目中」。OpenClaw 自己会退回它的默认工作区，其余在主目录下跑。
                projectPath = await store.homeDirectory
            }
            // startTask 还没有 id，所有权只能等连接器把 id 还回来才认领得上。
            let outcome: ConnectorOutcome
            if let target {
                outcome = try await target.connector.start(connectorId: target.connectorId, projectPath: projectPath,
                                                           prompt: payload.prompt, images: images)
            } else {
                outcome = try await connector.start(projectPath: projectPath, prompt: payload.prompt, images: images,
                                                    selection: selection)
            }
            let taskId = try normalized(outcome.taskId, kind: kind)
            // 先 claim 再按需 release：即使连接器不保留所有权，这一手也给新任务挣到了
            // `TaskStore.liveHandoffGrace` 那段宽限——SQLite 还没落盘时它不会被当成"消失了"。
            await store.claimLive(taskId)
            if !outcome.retainsLiveOwnership { await store.releaseLive(taskId) }
            return taskId
        case .followUp:
            guard let payload = command.followUp else { throw DispatchFailure("缺少 followUp 载荷") }
            // 协议 2.7：worktree 里的会话只在原来的 worktree 里续聊。它已经被删掉时直接说清楚，
            // 不退回主仓库——那样改动会落进主工作区，和用户在桌面上的预期不一样。
            if let worktree = await store.task(id: payload.taskId)?.worktreePath,
               !FileManager.default.fileExists(atPath: worktree) {
                throw DispatchFailure("这个会话所在的 worktree 已经删掉了，没法在原来的目录里续聊：\(worktree)",
                                      taskId: payload.taskId)
            }
            return try await onTask(payload.taskId) { connector in
                // 下载放在 onTask 里：失败时由它交还所有权、带上 taskId。
                let images = try await self.receiveImages(command, payload.attachments, kind: connector.kind)
                return try await connector.followUp(taskId: payload.taskId, prompt: payload.prompt, images: images,
                                                    selection: ModelSelection(payload))
            }
        case .approve:
            guard let payload = command.approve else { throw DispatchFailure("缺少 approve 载荷") }
            return try await onTask(payload.taskId) { connector in
                try await connector.approve(taskId: payload.taskId, requestId: payload.requestId,
                                            decision: payload.decision, answers: payload.answers)
            }
        case .interrupt:
            guard let payload = command.interrupt else { throw DispatchFailure("缺少 interrupt 载荷") }
            return try await onTask(payload.taskId) { connector in
                try await connector.interrupt(taskId: payload.taskId)
            }
        case .fetchMessages:
            guard let payload = command.fetchMessages else { throw DispatchFailure("缺少 fetchMessages 载荷") }
            try await fetchMessages(payload)
            return payload.taskId
        case .fetchFile:
            guard let payload = command.fetchFile else { throw DispatchFailure("缺少 fetchFile 载荷") }
            try await fetchFile(payload)
            return payload.taskId
        case .setConnectorEnabled, .fetchChanges, .remoteControl:
            return nil // 走不到：execute 已经先分出去了。
        }
    }

    /// 把命令带的图下载到本机，按原顺序返回文件 URL；没带图返回空数组、不碰 inbox。
    /// 来源不收图（`ConnectorKind.acceptsImages`）时直接失败、不下载——下下来也只会被连接器拒掉。
    /// 失败文案由 `AttachmentInboxError` 给（「图片下载失败：…」），`describe` 原样取用。
    private func receiveImages(_ command: Command, _ attachments: [MessageAttachment]?,
                               kind: ConnectorKind) async throws -> [URL] {
        guard let attachments, !attachments.isEmpty else { return [] }
        guard kind.acceptsImages else { throw DispatchFailure("这个 Agent 暂不支持发图") }
        guard let inbox else { throw DispatchFailure("本机无法接收图片") }
        return try await inbox.receive(commandId: command.id, attachments: attachments, agentId: command.agentId)
    }

    /// 拉对话记录：读出来发一个 `taskMessages` 事件，回执只说成没成。
    ///
    /// **不认领所有权、不碰任务状态**——这是一次只读查询，不该让只读观察以为有人在实时驱动它。
    ///
    /// 有图还没传到 Relay 时先把文字发出去（已传过的图照样带上），上传放到后台，传完再读一遍、
    /// 再发一次。回执不等上传：图可能好几张、Relay 还有每小时限额，让手机干等文字不值得。
    private func fetchMessages(_ payload: Command.FetchMessages) async throws {
        let (kind, reader) = try messageReader(for: payload.taskId)
        let limit = min(payload.limit ?? TaskMessages.maxMessages, TaskMessages.maxMessages)
        let (entries, hasMore) = try await reader.entries(taskId: payload.taskId, limit: limit)
        await publish(entries, hasMore: hasMore, taskId: payload.taskId, kind: kind, reader: reader, limit: limit)
    }

    /// 读对话记录前的三道关：认得出来源、本机有读取器、来源没被停用。`fetchMessages` 与 `fetchFile` 共用。
    private func messageReader(for taskId: String) throws -> (ConnectorKind, any MessageReader) {
        guard let source = TaskSource(taskId: taskId), let kind = ConnectorKind(source) else {
            throw DispatchFailure("无法识别的任务 id：\(taskId)", taskId: taskId)
        }
        guard let reader = readers[kind] else {
            throw DispatchFailure("本机读不了 \(kind.rawValue) 的对话记录", taskId: taskId)
        }
        // 停用的来源连快照都不进，对话记录更不该给——OpenClaw 默认关闭正是为了私聊不出这台电脑，
        // 而它的默认会话 key（`agent:main:main`）谁都猜得到。
        guard store.connectors.isEnabled(kind) else {
            throw DispatchFailure("\(kind.rawValue) 连接器已停用", taskId: taskId)
        }
        return (kind, reader)
    }

    /// 补全并发出一次 `taskMessages`；有图没传好时放到后台传，传完再读一遍、再发一次。
    private func publish(_ entries: [TranscriptEntry], hasMore: Bool, taskId: String, kind: ConnectorKind,
                         reader: any MessageReader, limit: Int) async {
        let completed = await complete(entries, taskId: taskId)
        await emitMessages(taskId: taskId, messages: completed.messages, hasMore: hasMore)
        guard completed.hasPending, let attachments else { return }
        // 上传放后台：回执不等它。传完再读一遍、再发一次，手机上的图随之出现。
        Task { [weak self] in
            await attachments.drainPending()
            await self?.refreshMessages(taskId: taskId, kind: kind, reader: reader, limit: limit,
                                        attachments: attachments)
        }
    }

    /// 手机点了一张还没上传的文件卡片（协议 2.9）：复核之后上传，再发一次带 artifactId 的 `taskMessages`。
    ///
    /// **这是手机读 Mac 文件的唯一入口**，手机给的 `path` 一个字都不信：
    /// 1. 重读这个任务的对话，`messageId` 必须是一条 Agent 回复，`path` 必须在它**此刻**的识别结果里——
    ///    手机不能借这条命令读 Mac 上的任意文件，只能取 Agent 自己在回复里提到、且在项目目录里的文件；
    /// 2. 上传前再按同一套规则 `validate` 一次，结果必须还是同一个真实路径（文件可能刚被删或换成了软链接）。
    ///
    /// 与 `fetchMessages` 一样只读：不认领所有权、不碰任务状态；上传的文件也不进 `Task.artifacts`。
    private func fetchFile(_ payload: Command.FetchFile) async throws {
        let taskId = payload.taskId
        let (kind, reader) = try messageReader(for: taskId)
        guard let files else { throw DispatchFailure("本机无法取回文件", taskId: taskId) }
        guard let projectPath = await store.task(id: taskId)?.projectPath else {
            throw DispatchFailure("本机没有这个任务：\(taskId)", taskId: taskId)
        }
        let limit = TaskMessages.maxMessages
        let (entries, hasMore) = try await reader.entries(taskId: taskId, limit: limit)
        guard let entry = entries.first(where: { $0.message.id == payload.messageId }), entry.message.role == .agent,
              TranscriptFileRefs.resolve(entry.pathCandidates, projectPath: projectPath)
                  .contains(where: { $0.path == payload.path }) else {
            throw DispatchFailure("这个文件不在对话里", taskId: taskId)
        }
        guard let url = TranscriptFileRefs.validate(path: payload.path, projectPath: projectPath),
              url.path == payload.path else {
            throw DispatchFailure("这个文件已经不在项目里了", taskId: taskId)
        }
        _ = try await files.fetch(url: url)
        // 刚传好的 id 已进取回索引，`complete` 查得到；先发消息再回执，手机收到 ok 时卡片已经带上 id。
        await publish(entries, hasMore: hasMore, taskId: taskId, kind: kind, reader: reader, limit: limit)
    }

    /// 手机要看任务目录里没提交的改动（协议 2.11）：在任务的工作目录里读 git，打成一份 JSON 产物上传，返回产物 id；
    /// 一个改动都没有时不上传、返回 nil。手机打开任务详情就会先问一次，据此决定显不显示入口，所以这条路要便宜。
    ///
    /// 与 `fetchFile` 一样只读：不认领所有权、不碰任务状态，产物也不进 `Task.artifacts`。
    /// 目录用任务自己的工作目录（worktree 会话是 worktree），按取文件同一套规则挡掉 home、`/Users` 这类太宽的目录；
    /// 「不在项目中」的会话没有项目可看，直接拒绝。
    private func fetchChanges(_ payload: Command.FetchChanges) async throws -> String? {
        let taskId = payload.taskId
        guard let source = TaskSource(taskId: taskId), let kind = ConnectorKind(source) else {
            throw DispatchFailure("无法识别的任务 id：\(taskId)", taskId: taskId)
        }
        guard store.connectors.isEnabled(kind) else {
            throw DispatchFailure("\(kind.rawValue) 连接器已停用", taskId: taskId)
        }
        guard let task = await store.task(id: taskId) else {
            throw DispatchFailure("本机没有这个任务：\(taskId)", taskId: taskId)
        }
        guard task.outsideProject != true else {
            throw DispatchFailure("这个会话不在项目中，没有可看的改动", taskId: taskId)
        }
        guard let changes else { throw DispatchFailure("本机无法读取改动", taskId: taskId) }
        guard let directory = TranscriptFileRefs.projectRoot(task.workingDirectory) else {
            throw DispatchFailure("这个任务的目录已经不在了，或者不能读取", taskId: taskId)
        }
        do {
            return try await changes.upload(directory: directory)
        } catch {
            throw DispatchFailure(Self.describe(error), taskId: taskId)
        }
    }

    /// 上传结束后的那一次补发。**不再**因为还有没传好的图（失败、限额）发起下一轮后台上传：
    /// 一次 `fetchMessages` 最多补发一次，剩下的等手机下次拉取时再试，免得失败时无限重试。
    ///
    /// 已经没有命令可回执了，读失败只记日志。上传期间来源被停用就作罢——停用的来源不往外发对话。
    private func refreshMessages(taskId: String, kind: ConnectorKind, reader: any MessageReader, limit: Int,
                                 attachments: any MessageAttachmentResolving) async {
        guard store.connectors.isEnabled(kind) else {
            Self.log.info("\(kind.rawValue, privacy: .public) 已停用，不补发 \(taskId, privacy: .public) 的对话")
            return
        }
        do {
            let (entries, hasMore) = try await reader.entries(taskId: taskId, limit: limit)
            let completed = await complete(entries, taskId: taskId)
            await emitMessages(taskId: taskId, messages: completed.messages, hasMore: hasMore)
        } catch {
            if (error as? ConnectorError)?.containsPrivateDetail == true {
                Self.log.error("补发 \(taskId, privacy: .public) 的对话失败：\(Self.describe(error), privacy: .private)")
            } else {
                Self.log.error("补发 \(taskId, privacy: .public) 的对话失败：\(Self.describe(error), privacy: .public)")
            }
        }
    }

    /// 读取器的 entry → 外发的消息：填上已传好的图（`attachments`），再给 Agent 回复补文件卡片（`files`）。
    /// `hasPending` 表示还有图没传，调用方决定要不要后台传完再发一次。
    ///
    /// 文件卡片按任务的项目目录校验（`TranscriptFileRefs.resolve`）：store 里没有这个任务就不知道项目目录，
    /// 一张卡片都不给——宁可少给，也不拿别的目录兜底。
    ///
    /// 最后丢掉「没字、没图、没文件、也没有图在排队」的消息：读取器保留纯图消息，但图可能永远拿不到
    /// （文件已删、解不出、没有上传器），这样的消息发出去只是手机上一个空气泡。还有图在排队的照发，
    /// 手机先画「图片」占位，补发时带上图。
    private func complete(_ entries: [TranscriptEntry], taskId: String) async -> (messages: [Message], hasPending: Bool) {
        let agentId = await store.identity.agentId
        let resolved = await attachments?.resolve(entries, agentId: agentId)
        var messages = resolved?.messages ?? entries.map(\.message)
        let pending = resolved?.pending ?? Array(repeating: false, count: entries.count)
        if entries.contains(where: { $0.message.role == .agent && !$0.pathCandidates.isEmpty }),
           let projectPath = await store.task(id: taskId)?.projectPath {
            for (index, entry) in entries.enumerated() where entry.message.role == .agent {
                var refs = TranscriptFileRefs.resolve(entry.pathCandidates, projectPath: projectPath)
                guard !refs.isEmpty else { continue }
                if let files {
                    for ref in refs.indices {
                        refs[ref].artifactId = await files.artifactId(for: URL(fileURLWithPath: refs[ref].path))
                    }
                }
                messages[index].files = refs
            }
        }
        let kept = zip(messages, pending).filter { message, waiting in
            waiting || Self.hasVisibleContent(message)
        }.map(\.0)
        return (kept, resolved?.hasPending ?? false)
    }

    /// 有字、有图或有文件卡片。与 ClientCore 的 `Message.hasVisibleContent` 同一判据（文字按去掉空白后算）。
    private static func hasVisibleContent(_ message: Message) -> Bool {
        !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(message.attachments ?? []).isEmpty
            || !(message.files ?? []).isEmpty
    }

    private func emitMessages(taskId: String, messages: [Message], hasMore: Bool) async {
        // agentId 留空由 Relay 按连接盖章，和分片里改写 task.agentId 是同一个道理。
        await store.emit(.taskMessages(TaskMessages(taskId: taskId, agentId: "", messages: messages,
                                                    hasMore: hasMore, fetchedAt: timestamp())))
    }

    /// 针对已有任务的三条命令共用的骨架：解析前缀 → 找连接器 → 确认任务在本机 →
    /// 认领所有权 → 执行 → 无论成败都交还。
    private func onTask(_ taskId: String,
                        _ body: (any TaskConnector) async throws -> ConnectorOutcome) async throws -> String {
        guard let source = TaskSource(taskId: taskId), let kind = ConnectorKind(source) else {
            throw DispatchFailure("无法识别的任务 id：\(taskId)", taskId: taskId)
        }
        let connector = try self.connector(for: kind)
        // 只查"本机认不认识这个 id"，不查 controllable：那面旗子是给客户端画按钮用的提示，
        // 由快照的那一刻决定，命令到达时早就可能过期了（桌面上刚开跑 = controllable 变 false）。
        // 真正能不能执行由连接器说了算，它给出的失败原因也比"不可控制"具体得多。
        guard await store.task(id: taskId) != nil else {
            throw DispatchFailure("本机没有这个任务：\(taskId)", taskId: taskId)
        }
        await store.claimLive(taskId)
        do {
            let outcome = try await body(connector)
            let resulting = try normalized(outcome.taskId, kind: kind)
            // Claude 对桌面会话续聊会分支出新 session：新 id 同样要挡住只读观察。
            var touched = [taskId]
            if resulting != taskId {
                await store.claimLive(resulting)
                touched.append(resulting)
            }
            for id in touched where !(outcome.retainsLiveOwnership && id == resulting) {
                await store.releaseLive(id)
            }
            return resulting
        } catch {
            // 失败路径同样要交还，否则这个 id 会永远躲开只读观察，任务卡在最后一个已知状态。
            await store.releaseLive(taskId)
            if error is CancellationError { throw error }
            throw DispatchFailure(Self.describe(error), taskId: taskId)
        }
    }

    private func connector(for kind: ConnectorKind) throws -> any TaskConnector {
        guard let connector = connectors[kind] else {
            throw DispatchFailure("本机没有 \(kind.rawValue) 连接器")
        }
        // 被用户关掉的 Connector 视同"什么都没有"：它的任务连快照都不进，自然也不该接命令。
        guard store.connectors.isEnabled(kind) else {
            throw DispatchFailure("\(kind.rawValue) 连接器已停用")
        }
        return connector
    }

    /// 连接器可以只返回后端的原生 id，这里补上 `<kind>:` 前缀；已经带了本连接器前缀的原样放行。
    /// 带着别人前缀的（`codex` 连接器返回 `claude:…`）按原生 id 处理并重新加前缀——
    /// 一个连接器无权把任务记到另一个来源名下，`TaskStore` 也会拒收前缀对不上的任务。
    private func normalized(_ id: String, kind: ConnectorKind) throws -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DispatchFailure("\(kind.rawValue) 连接器没有返回任务 id") }
        guard let source = TaskSource(taskId: trimmed), ConnectorKind(source) == kind else {
            return "\(kind.rawValue):\(trimmed)"
        }
        return trimmed
    }

    private func timestamp() -> String { ProtocolJSON.timestamp(now()) }

    /// 命令自带的目标 taskId（如果这个 kind 有的话）。失败回执靠它让客户端知道是哪条任务出的事。
    private static func targetTaskId(_ command: Command) -> String? {
        switch command.kind {
        case .followUp: command.followUp?.taskId
        case .approve: command.approve?.taskId
        case .interrupt: command.interrupt?.taskId
        case .fetchMessages: command.fetchMessages?.taskId
        case .fetchFile: command.fetchFile?.taskId
        case .fetchChanges: command.fetchChanges?.taskId
        case .startTask, .setConnectorEnabled, .remoteControl: nil
        }
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? DispatchFailure { return failure.message }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty { return localized }
        return String(describing: error)
    }

    private static func truncate(_ message: String) -> String {
        message.count <= errorLimit ? message : String(message.prefix(errorLimit))
    }
}
