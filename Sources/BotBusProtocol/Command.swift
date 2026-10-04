import Foundation

public struct Command: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case startTask, followUp, approve, interrupt, setConnectorEnabled, fetchMessages, fetchFile, fetchChanges
        case remoteControl, mergeWorktree, deleteTask, removeProject, restartConnector
    }

    public struct StartTask: Codable, Hashable, Sendable {
        public var source: TaskSource
        /// 会话的工作目录。协议 2.6 起空串表示「不在项目中」：由电脑决定在哪里跑（主目录，或该 Agent 的默认工作区）。
        public var projectPath: String
        public var prompt: String
        /// 协议 2.6：新建项目的文件夹名。有它时电脑在 `AgentInfo.projectsRoot` 下建这个子文件夹再开始，
        /// `projectPath` 忽略（发空串）。只能是一层文件夹名，见 `isValidNewProjectName`。
        public var newProject: String?
        /// 手机发图开新任务（协议 2.9）。
        public var attachments: [MessageAttachment]?
        /// 协议 2.13：发给哪个 ACP agent。`source = acp` 时必填，其余来源省略。
        public var connectorId: String?
        /// 协议 3.2：这条会话用哪个模型（`ConnectorInfo.models` 里的 `id`），之后的续聊沿用。省略 = agent 默认。
        public var model: String?
        /// 协议 3.2：这条会话的思考强度，之后沿用。省略 = 按模型默认。
        public var effort: String?
        /// 协议 3.3：把这条会话所在项目的「自动批准」设为开（true）或关（false），从第一轮起生效、之后沿用。
        /// 省略 = 不动。只有报了 `ConnectorInfo.canAutoApprove` 的 agent 收；「不在项目中」的会话不收。
        public var autoApprove: Bool?
        /// 协议 3.4：在项目仓库新开的 git worktree 里跑（`<仓库>/.claude/worktrees/<名字>`，分支 `botbus/<名字>`）。
        /// 只写 true；只和非空的 `projectPath` 一起出现，不和 `newProject` 同时出现，OpenClaw 不收。
        /// 电脑建不了（不是 git 仓库、还没有提交、detached HEAD）时照旧在 `projectPath` 里跑。
        public var worktree: Bool?
        /// 协议 3.9：新项目文件夹建在哪个目录下（电脑上的绝对路径）。只和 `newProject` 一起出现；
        /// 省略 = 建在 `AgentInfo.projectsRoot` 下。只有报了 `AgentInfo.canChooseProjectParent` 的电脑收。
        public var newProjectParent: String?

        public init(source: TaskSource, projectPath: String, prompt: String, newProject: String? = nil,
                    attachments: [MessageAttachment]? = nil, connectorId: String? = nil,
                    model: String? = nil, effort: String? = nil, autoApprove: Bool? = nil, worktree: Bool? = nil,
                    newProjectParent: String? = nil) {
            self.source = source
            self.projectPath = projectPath
            self.prompt = prompt
            self.newProject = newProject
            self.attachments = attachments
            self.connectorId = connectorId
            self.model = model
            self.effort = effort
            self.autoApprove = autoApprove
            self.worktree = worktree
            self.newProjectParent = newProjectParent
        }

        private enum CodingKeys: String, CodingKey {
            case source, projectPath, prompt, newProject, attachments, connectorId, model, effort, autoApprove, worktree
            case newProjectParent
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try container.decode(TaskSource.self, forKey: .source)
            projectPath = try container.decode(String.self, forKey: .projectPath)
            prompt = try container.decode(String.self, forKey: .prompt)
            newProject = try container.decodeIfPresent(String.self, forKey: .newProject)
            attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments)
            connectorId = try container.decodeIfPresent(String.self, forKey: .connectorId)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            effort = try container.decodeIfPresent(String.self, forKey: .effort)
            autoApprove = try container.decodeIfPresent(Bool.self, forKey: .autoApprove)
            worktree = try container.decodeIfPresent(Bool.self, forKey: .worktree)
            newProjectParent = try container.decodeIfPresent(String.self, forKey: .newProjectParent)
            if let newProjectParent {
                guard newProject != nil, !newProjectParent.isEmpty,
                      newProjectParent.count <= Self.maxNewProjectParentLength else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .newProjectParent, in: container,
                        debugDescription: "newProjectParent must be a non-empty path and only appear with newProject")
                }
            }
            if let model, !ModelOption.isValidId(model) {
                throw DecodingError.dataCorruptedError(forKey: .model, in: container, debugDescription: "invalid model id")
            }
            if let effort, !ModelOption.isValidEffort(effort) {
                throw DecodingError.dataCorruptedError(forKey: .effort, in: container, debugDescription: "invalid effort")
            }
            let valid = source == .acp
                ? connectorId.map(ConnectorRef.isValidAcpId) == true
                : connectorId == nil
            guard valid else {
                throw DecodingError.dataCorruptedError(
                    forKey: .connectorId, in: container,
                    debugDescription: "connectorId is required for source acp and only allowed there")
            }
            if let worktree {
                guard worktree, newProject == nil, source != .openclaw,
                      !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .worktree, in: container,
                        debugDescription: "worktree must be true, with a non-empty projectPath, without newProject, not for openclaw")
                }
            }
        }

        public static let maxNewProjectNameLength = 80
        /// 协议 3.9：`newProjectParent` 的长度上限（字符）。
        public static let maxNewProjectParentLength = 1024

        /// 新项目名能不能用：去掉首尾空白后非空、不超过 80 字、只有一层（不含 `/`、`\`、`:`）、
        /// 不以 `.` 开头（挡住 `..` 与隐藏目录）、没有控制字符。手机据此提示，电脑据此拒绝——
        /// 手机给的只能是一个文件夹名，目录永远落在电脑自己设的根目录下面。
        public static func isValidNewProjectName(_ name: String) -> Bool {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= maxNewProjectNameLength, !trimmed.hasPrefix(".") else { return false }
            return !trimmed.unicodeScalars.contains { scalar in
                "/\\:".unicodeScalars.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
            }
        }
    }

    public struct FollowUp: Codable, Hashable, Sendable {
        public var taskId: String
        public var prompt: String
        /// 手机发图追加消息（协议 2.9）。
        public var attachments: [MessageAttachment]?
        /// 协议 3.2：从这一轮起换成这个模型（`ConnectorInfo.models` 里的 `id`），之后的续聊沿用。省略 = 不换。
        public var model: String?
        /// 协议 3.2：从这一轮起换成这档思考强度，之后沿用。省略 = 不换。
        public var effort: String?
        /// 协议 3.3：把这条会话所在项目的「自动批准」设为开（true）或关（false），从这一轮起生效、之后沿用。
        /// 省略 = 不动。规则同 `StartTask.autoApprove`。
        public var autoApprove: Bool?

        public init(taskId: String, prompt: String, attachments: [MessageAttachment]? = nil,
                    model: String? = nil, effort: String? = nil, autoApprove: Bool? = nil) {
            self.taskId = taskId
            self.prompt = prompt
            self.attachments = attachments
            self.model = model
            self.effort = effort
            self.autoApprove = autoApprove
        }

        private enum CodingKeys: String, CodingKey { case taskId, prompt, attachments, model, effort, autoApprove }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            taskId = try container.decode(String.self, forKey: .taskId)
            prompt = try container.decode(String.self, forKey: .prompt)
            attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            effort = try container.decodeIfPresent(String.self, forKey: .effort)
            autoApprove = try container.decodeIfPresent(Bool.self, forKey: .autoApprove)
            if let model, !ModelOption.isValidId(model) {
                throw DecodingError.dataCorruptedError(forKey: .model, in: container, debugDescription: "invalid model id")
            }
            if let effort, !ModelOption.isValidEffort(effort) {
                throw DecodingError.dataCorruptedError(forKey: .effort, in: container, debugDescription: "invalid effort")
            }
        }
    }

    public struct Approve: Codable, Hashable, Sendable {
        public enum Decision: String, Codable, Sendable, CaseIterable { case allow, deny }
        public var taskId: String
        public var requestId: String
        public var decision: Decision
        /// 协议 2.14：回答 `PendingRequest.questions`。键是 `PendingQuestion.id`，值是选中的选项 `label`
        /// （多选时多个），也可以是用户自己打的字。只和 `decision = allow` 一起出现；`deny` 表示不回答。
        public var answers: [String: [String]]?
        public init(taskId: String, requestId: String, decision: Decision, answers: [String: [String]]? = nil) {
            self.taskId = taskId
            self.requestId = requestId
            self.decision = decision
            self.answers = answers
        }
    }

    public struct Interrupt: Codable, Hashable, Sendable {
        public var taskId: String
        public init(taskId: String) { self.taskId = taskId }
    }

    public struct SetConnectorEnabled: Codable, Hashable, Sendable {
        public var connector: ConnectorKind
        public var enabled: Bool
        /// 协议 2.13：开关哪个 ACP agent。`connector = acp` 时必填。
        public var connectorId: String?

        public init(connector: ConnectorKind, enabled: Bool, connectorId: String? = nil) {
            self.connector = connector
            self.enabled = enabled
            self.connectorId = connectorId
        }

        public var ref: ConnectorRef { ConnectorRef(kind: connector, id: connectorId) }

        private enum CodingKeys: String, CodingKey { case connector, enabled, connectorId }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            connector = try container.decode(ConnectorKind.self, forKey: .connector)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            connectorId = try container.decodeIfPresent(String.self, forKey: .connectorId)
            let valid = connector == .acp
                ? connectorId.map(ConnectorRef.isValidAcpId) == true
                : connectorId == nil
            guard valid else {
                throw DecodingError.dataCorruptedError(
                    forKey: .connectorId, in: container,
                    debugDescription: "connectorId is required for connector acp and only allowed there")
            }
        }
    }

    /// 协议 3.9：在电脑上重启一个 Agent 的连接——先像停用那样收掉连接和后台进程（在跑的会话被中断），
    /// 等收尾完再重新启用。只对报了 `AgentInfo.canRestartConnectors` 的电脑发。停止 / 启动用 `setConnectorEnabled`。
    public struct RestartConnector: Codable, Hashable, Sendable {
        public var connector: ConnectorKind
        /// 重启哪个 ACP agent。`connector = acp` 时必填，其余 kind 省略。
        public var connectorId: String?

        public init(connector: ConnectorKind, connectorId: String? = nil) {
            self.connector = connector
            self.connectorId = connectorId
        }

        public init(_ ref: ConnectorRef) { self.init(connector: ref.kind, connectorId: ref.id) }

        public var ref: ConnectorRef { ConnectorRef(kind: connector, id: connectorId) }

        private enum CodingKeys: String, CodingKey { case connector, connectorId }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            connector = try container.decode(ConnectorKind.self, forKey: .connector)
            connectorId = try container.decodeIfPresent(String.self, forKey: .connectorId)
            let valid = connector == .acp
                ? connectorId.map(ConnectorRef.isValidAcpId) == true
                : connectorId == nil
            guard valid else {
                throw DecodingError.dataCorruptedError(
                    forKey: .connectorId, in: container,
                    debugDescription: "connectorId is required for connector acp and only allowed there")
            }
        }
    }

    /// 拉取一个任务的对话记录。`limit` 省略时由 Agent 取协议上限。
    public struct FetchMessages: Codable, Hashable, Sendable {
        public var taskId: String
        public var limit: Int?
        public init(taskId: String, limit: Int? = nil) {
            self.taskId = taskId
            self.limit = limit
        }
    }

    /// 手机点了一个尚未上传的文件产物，让 Agent 按路径读盘上传（协议 2.9）。
    public struct FetchFile: Codable, Hashable, Sendable {
        public var taskId: String
        public var messageId: String
        public var path: String
        public init(taskId: String, messageId: String, path: String) {
            self.taskId = taskId
            self.messageId = messageId
            self.path = path
        }
    }

    /// 看任务所在目录里还没提交的改动（协议 2.11）。Mac 在任务的工作目录里跑只读的 git 命令，
    /// 把改动清单（`WorkingChanges`）作为一份 JSON 产物上传，产物 id 随 `CommandResult.artifactId` 返回。
    public struct FetchChanges: Codable, Hashable, Sendable {
        public var taskId: String
        public init(taskId: String) { self.taskId = taskId }
    }

    /// 协议 3.4：把 BotBus 从手机开的 worktree 会话的改动压成一个提交，合并回建 worktree 时的检出分支，
    /// 然后删掉 worktree 与分支、把会话从列表隐藏。只对 `WorkingChanges.mergeTarget` 出现过的会话发。
    public struct MergeWorktree: Codable, Hashable, Sendable {
        public var taskId: String
        public init(taskId: String) { self.taskId = taskId }
    }

    /// 协议 3.8：永久删除原生会话记录，不删除项目文件。只能用于停止的会话。
    public struct DeleteTask: Codable, Hashable, Sendable {
        public var taskId: String
        public init(taskId: String) { self.taskId = taskId }
        private enum CodingKeys: String, CodingKey { case taskId }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            taskId = try container.decode(String.self, forKey: .taskId)
            guard !taskId.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .taskId, in: container, debugDescription: "taskId must not be empty")
            }
        }
    }

    /// 协议 3.8：移出 BotBus 电脑端项目列表，保留文件和会话；新活动会恢复显示。
    public struct RemoveProject: Codable, Hashable, Sendable {
        public var projectPath: String
        public init(projectPath: String) { self.projectPath = projectPath }
        private enum CodingKeys: String, CodingKey { case projectPath }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            projectPath = try container.decode(String.self, forKey: .projectPath)
            guard !projectPath.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .projectPath, in: container, debugDescription: "projectPath must not be empty")
            }
        }
    }

    /// 远程操作这台电脑的桌面（协议 2.12）。人不在电脑前、agent 卡在只有人能做的那一步时
    /// （登录、密码、确认弹窗），手机接管鼠标键盘。
    ///
    /// `enabled` 为 true 时 Mac 起本机的远程操作服务，并把它分享成一个预览，预览产物 id 随
    /// `CommandResult.artifactId` 回来，手机打开它就是远程画面；false 时停掉服务与分享。
    /// 重复开启返回同一个还没过期的预览，不会叠开第二个。
    ///
    /// 没有辅助功能权限时**依然会成功**，只是那个预览只能看不能操作——画面本身只要录屏权限。
    /// 权限状态在页面顶部显示，引导用户回电脑的设置里打开。
    public struct RemoteControl: Codable, Hashable, Sendable {
        public var enabled: Bool
        public init(enabled: Bool) { self.enabled = enabled }
    }

    public var id: String
    public var createdAt: String
    /// 目标电脑，必填；Relay 据此路由，Agent 应断言它等于自己的 agentId。
    public var agentId: String
    public var kind: Kind
    public var startTask: StartTask?
    public var followUp: FollowUp?
    public var approve: Approve?
    public var interrupt: Interrupt?
    public var setConnectorEnabled: SetConnectorEnabled?
    public var fetchMessages: FetchMessages?
    public var fetchFile: FetchFile?
    public var fetchChanges: FetchChanges?
    public var remoteControl: RemoteControl?
    public var mergeWorktree: MergeWorktree?
    public var deleteTask: DeleteTask?
    public var removeProject: RemoveProject?
    public var restartConnector: RestartConnector?

    public init(id: String = UUID().uuidString.lowercased(), createdAt: String, agentId: String, kind: Kind,
                startTask: StartTask? = nil, followUp: FollowUp? = nil,
                approve: Approve? = nil, interrupt: Interrupt? = nil,
                setConnectorEnabled: SetConnectorEnabled? = nil, fetchMessages: FetchMessages? = nil,
                fetchFile: FetchFile? = nil, fetchChanges: FetchChanges? = nil,
                remoteControl: RemoteControl? = nil, mergeWorktree: MergeWorktree? = nil,
                deleteTask: DeleteTask? = nil, removeProject: RemoveProject? = nil,
                restartConnector: RestartConnector? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.agentId = agentId
        self.kind = kind
        self.startTask = startTask
        self.followUp = followUp
        self.approve = approve
        self.interrupt = interrupt
        self.setConnectorEnabled = setConnectorEnabled
        self.fetchMessages = fetchMessages
        self.fetchFile = fetchFile
        self.fetchChanges = fetchChanges
        self.remoteControl = remoteControl
        self.mergeWorktree = mergeWorktree
        self.deleteTask = deleteTask
        self.removeProject = removeProject
        self.restartConnector = restartConnector
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, agentId, kind, startTask, followUp, approve, interrupt, setConnectorEnabled, fetchMessages
        case fetchFile, fetchChanges, remoteControl, mergeWorktree, deleteTask, removeProject, restartConnector
    }

    private var hasPayloadForKind: Bool {
        switch kind {
        case .startTask: startTask != nil
        case .followUp: followUp != nil
        case .approve: approve != nil
        case .interrupt: interrupt != nil
        case .setConnectorEnabled: setConnectorEnabled != nil
        case .fetchMessages: fetchMessages != nil
        case .fetchFile: fetchFile != nil
        case .fetchChanges: fetchChanges != nil
        case .remoteControl: remoteControl != nil
        case .mergeWorktree: mergeWorktree != nil
        case .deleteTask: deleteTask != nil
        case .removeProject: removeProject != nil
        case .restartConnector: restartConnector != nil
        }
    }

    /// 与 TypeScript 端的 zod refine 对齐：与 kind 同名的载荷必须存在，否则解码失败。
    /// 其余载荷按协议「以 kind 为准」忽略——解码时直接丢弃，编码时不写出。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        agentId = try container.decode(String.self, forKey: .agentId)
        kind = try container.decode(Kind.self, forKey: .kind)
        startTask = try container.decodeIfPresent(StartTask.self, forKey: .startTask)
        followUp = try container.decodeIfPresent(FollowUp.self, forKey: .followUp)
        approve = try container.decodeIfPresent(Approve.self, forKey: .approve)
        interrupt = try container.decodeIfPresent(Interrupt.self, forKey: .interrupt)
        setConnectorEnabled = try container.decodeIfPresent(SetConnectorEnabled.self, forKey: .setConnectorEnabled)
        fetchMessages = try container.decodeIfPresent(FetchMessages.self, forKey: .fetchMessages)
        fetchFile = try container.decodeIfPresent(FetchFile.self, forKey: .fetchFile)
        fetchChanges = try container.decodeIfPresent(FetchChanges.self, forKey: .fetchChanges)
        remoteControl = try container.decodeIfPresent(RemoteControl.self, forKey: .remoteControl)
        mergeWorktree = try container.decodeIfPresent(MergeWorktree.self, forKey: .mergeWorktree)
        deleteTask = try container.decodeIfPresent(DeleteTask.self, forKey: .deleteTask)
        removeProject = try container.decodeIfPresent(RemoveProject.self, forKey: .removeProject)
        restartConnector = try container.decodeIfPresent(RestartConnector.self, forKey: .restartConnector)

        guard hasPayloadForKind else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "payload for kind \(kind.rawValue) is missing")
        }
        if kind != .startTask { startTask = nil }
        if kind != .followUp { followUp = nil }
        if kind != .approve { approve = nil }
        if kind != .interrupt { interrupt = nil }
        if kind != .setConnectorEnabled { setConnectorEnabled = nil }
        if kind != .fetchMessages { fetchMessages = nil }
        if kind != .fetchFile { fetchFile = nil }
        if kind != .fetchChanges { fetchChanges = nil }
        if kind != .remoteControl { remoteControl = nil }
        if kind != .mergeWorktree { mergeWorktree = nil }
        if kind != .deleteTask { deleteTask = nil }
        if kind != .removeProject { removeProject = nil }
        if kind != .restartConnector { restartConnector = nil }
    }

    /// 编码方向同样守住这条规则：载荷缺失直接拒绝编码，与 kind 不符的载荷不写出。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(agentId, forKey: .agentId)
        try container.encode(kind, forKey: .kind)
        switch kind {
        case .startTask: try container.encode(required(startTask, encoder), forKey: .startTask)
        case .followUp: try container.encode(required(followUp, encoder), forKey: .followUp)
        case .approve: try container.encode(required(approve, encoder), forKey: .approve)
        case .interrupt: try container.encode(required(interrupt, encoder), forKey: .interrupt)
        case .setConnectorEnabled:
            try container.encode(required(setConnectorEnabled, encoder), forKey: .setConnectorEnabled)
        case .fetchMessages: try container.encode(required(fetchMessages, encoder), forKey: .fetchMessages)
        case .fetchFile: try container.encode(required(fetchFile, encoder), forKey: .fetchFile)
        case .fetchChanges: try container.encode(required(fetchChanges, encoder), forKey: .fetchChanges)
        case .remoteControl: try container.encode(required(remoteControl, encoder), forKey: .remoteControl)
        case .mergeWorktree: try container.encode(required(mergeWorktree, encoder), forKey: .mergeWorktree)
        case .deleteTask: try container.encode(required(deleteTask, encoder), forKey: .deleteTask)
        case .removeProject: try container.encode(required(removeProject, encoder), forKey: .removeProject)
        case .restartConnector:
            try container.encode(required(restartConnector, encoder), forKey: .restartConnector)
        }
    }

    private func required<T>(_ payload: T?, _ encoder: Encoder) throws -> T {
        guard let payload else {
            throw EncodingError.invalidValue(self, EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "payload for kind \(kind.rawValue) is missing"))
        }
        return payload
    }

    // 客户端应通过下面的构造器创建命令，保证 kind 与载荷一致。
    public static func startTask(_ payload: StartTask, createdAt: String,
                                 id: String = UUID().uuidString.lowercased(),
                                 agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .startTask, startTask: payload)
    }

    public static func followUp(_ payload: FollowUp, createdAt: String,
                                id: String = UUID().uuidString.lowercased(),
                                agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .followUp, followUp: payload)
    }

    public static func approve(_ payload: Approve, createdAt: String,
                               id: String = UUID().uuidString.lowercased(),
                               agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .approve, approve: payload)
    }

    public static func interrupt(_ payload: Interrupt, createdAt: String,
                                 id: String = UUID().uuidString.lowercased(),
                                 agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .interrupt, interrupt: payload)
    }

    public static func fetchMessages(_ payload: FetchMessages, createdAt: String,
                                     id: String = UUID().uuidString.lowercased(),
                                     agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .fetchMessages, fetchMessages: payload)
    }

    public static func fetchFile(_ payload: FetchFile, createdAt: String,
                                 id: String = UUID().uuidString.lowercased(),
                                 agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .fetchFile, fetchFile: payload)
    }

    public static func fetchChanges(_ payload: FetchChanges, createdAt: String,
                                    id: String = UUID().uuidString.lowercased(),
                                    agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .fetchChanges, fetchChanges: payload)
    }

    public static func remoteControl(_ payload: RemoteControl, createdAt: String,
                                     id: String = UUID().uuidString.lowercased(),
                                     agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .remoteControl, remoteControl: payload)
    }

    public static func setConnectorEnabled(_ payload: SetConnectorEnabled, createdAt: String,
                                           id: String = UUID().uuidString.lowercased(),
                                           agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .setConnectorEnabled,
                setConnectorEnabled: payload)
    }

    public static func restartConnector(_ payload: RestartConnector, createdAt: String,
                                       id: String = UUID().uuidString.lowercased(),
                                       agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .restartConnector, restartConnector: payload)
    }

    public static func mergeWorktree(_ payload: MergeWorktree, createdAt: String,
                                     id: String = UUID().uuidString.lowercased(),
                                     agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .mergeWorktree, mergeWorktree: payload)
    }
    public static func deleteTask(_ payload: DeleteTask, createdAt: String,
                                  id: String = UUID().uuidString.lowercased(), agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .deleteTask, deleteTask: payload)
    }

    public static func removeProject(_ payload: RemoveProject, createdAt: String,
                                     id: String = UUID().uuidString.lowercased(), agentId: String) -> Command {
        Command(id: id, createdAt: createdAt, agentId: agentId, kind: .removeProject, removeProject: payload)
    }
}
