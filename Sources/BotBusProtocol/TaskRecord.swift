import Foundation

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case running, waitingApproval, waitingInput, completed, failed, interrupted, idle
}

/// 任务来源。协议 2.5 起加入 `hermes`、`pi`、`openclaw`，2.13 起加入 `acp`，3.1 起加入 `dsh`（DeepSeek Harness）；
/// 接收方遇未知值拒绝整条。
public enum TaskSource: String, Codable, Sendable, CaseIterable {
    case codex, claude, hermes, pi, openclaw, acp, dsh
}

public enum TaskOrigin: String, Codable, Sendable, CaseIterable {
    case watch, desktop
}

public struct PendingRequest: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case command, fileChange, permission, input
    }

    public var id: String
    public var kind: Kind
    public var summary: String
    public var detail: String?
    public var question: String?
    /// 协议 2.14：agent 给了可选项的提问（Claude 的 AskUserQuestion、Codex 的 requestUserInput），
    /// 随 `kind = input` 出现。客户端据此画选项，选好了用 `approve` 带 `answers` 回；
    /// `question` 仍是一段写好选项的纯文字，给不认这个字段的旧客户端看。
    /// 挂在审批（`command` / `fileChange` / `permission`）上时是「允许」的几种范围
    /// （OpenClaw 的只这一次 / 以后都允许、ACP 的 `allow_once` / `allow_always`）：
    /// 客户端默认选第一个，「批准」带 `answers`，「拒绝」照旧不带；旧客户端不带 `answers` 时 Agent 取第一个。
    public var questions: [PendingQuestion]?

    public init(id: String, kind: Kind, summary: String, detail: String? = nil, question: String? = nil,
                questions: [PendingQuestion]? = nil) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.question = question
        self.questions = questions
    }
}

/// 一道带选项的提问（协议 2.14）。
public struct PendingQuestion: Codable, Hashable, Sendable, Identifiable {
    /// 同一个请求里唯一；回答时作 `Command.Approve.answers` 的键。
    public var id: String
    public var question: String
    /// 很短的标签（Claude 的 `header`，如「部署到哪」）。
    public var header: String?
    /// `true` = 可以多选；单选时整个键省略。
    public var multiSelect: Bool?
    /// 可能为空：只要一句话的提问。客户端总是允许直接打字回答。
    public var options: [PendingOption]

    public init(id: String, question: String, header: String? = nil, multiSelect: Bool = false,
                options: [PendingOption]) {
        self.id = id
        self.question = question
        self.header = header
        self.multiSelect = multiSelect ? true : nil
        self.options = options
    }

    public var allowsMultiple: Bool { multiSelect == true }

    /// 生产方负责截断到这些上限，Relay 按它校验。
    public static let maxQuestions = 8
    public static let maxOptions = 16
}

public struct PendingOption: Codable, Hashable, Sendable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// 协议中的 `Task`。Swift 侧改名避免与 Swift Concurrency 的 Task 冲突，JSON 结构不变。
public struct TaskRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// 所属电脑；全局唯一键是 (agentId, id)。
    public var agentId: String
    public var source: TaskSource
    public var title: String
    /// 会话所属项目的路径，客户端按它分组。协议 2.7 起，开在 git worktree 里的会话填**主仓库**的路径，
    /// 实际工作目录另放在 `worktreePath`；其余会话就是 cwd。
    public var projectPath: String
    /// `projectPath` 的最后一段。
    public var projectName: String
    public var status: TaskStatus
    public var lastMessage: String?
    public var pendingRequest: PendingRequest?
    public var origin: TaskOrigin
    public var controllable: Bool
    public var startedAt: String
    public var updatedAt: String
    /// agent 回传的产物（协议 2.3），最多 `maxArtifacts` 个，**新的在前**；没有产物时用 nil，
    /// 编码时整个键省略（不要写成 `[]`）。由 Agent 的 TaskStore 附加，连接器与观察者不感知。
    ///
    /// 可选而非默认空数组是为了兼容：旧版本对端不发这个键，合成的 Codable 对缺键给 nil，
    /// 不会让整条任务（进而整份快照）解码失败。
    public var artifacts: [Artifact]?
    /// 协议 2.6：这条会话不在任何项目里（开在主目录、下载目录、临时目录或 Agent 的默认工作区）。
    /// 只有 true 或省略两种取值，由 Agent 的 TaskStore 按本机规则判定，连接器与观察者不感知；
    /// 客户端据此把它放进「不在项目中」，而不是给它的目录补一个项目。
    public var outsideProject: Bool?
    /// 协议 2.7：会话实际的工作目录，只在它是某个仓库的 git worktree 时出现（此时 `projectPath` 是主仓库），
    /// 否则省略。由 Agent 的 TaskStore 解析，连接器与观察者不感知；续聊照旧在这个目录里跑。
    public var worktreePath: String?
    /// 协议 2.10：失败后检测到的系统授权弹窗证据，不代表当前待审批状态。
    public var systemPermission: SystemPermissionNotice?
    /// 协议 2.13：ACP agent 的 id。只在 `source = acp` 时出现，且必须出现。
    public var connectorId: String?
    /// 协议 3.2：这条会话下一轮会用的模型（`ModelOption.id` 的写法），电脑知道时才有。
    public var model: String?
    /// 协议 3.2：下一轮的思考强度，电脑知道时才有；省略不代表"不思考"，只是不知道（按模型默认）。
    public var effort: String?
    /// 协议 3.3：这条会话所在的项目开了「自动批准」（同 `Project.autoApprove`）。只写 true，没开时整个键省略；
    /// 由 Agent 的 TaskStore 按 `projectPath` 附加，连接器与观察者不感知。
    public var autoApprove: Bool?
    /// 协议 3.7：电脑对这次失败的诊断，只在 `status = failed` 时出现。连接器认出原因时带上，
    /// 或由 Agent 的 TaskStore 在失败后探测工作目录得到（见 `DirectoryProbe`）。
    public var diagnosis: FailureDiagnosis?

    /// 协议规定的单任务产物上限。
    public static let maxArtifacts = 10

    public init(id: String, agentId: String, source: TaskSource, title: String, projectPath: String,
                projectName: String, status: TaskStatus, lastMessage: String? = nil,
                pendingRequest: PendingRequest? = nil, origin: TaskOrigin, controllable: Bool,
                startedAt: String, updatedAt: String, artifacts: [Artifact]? = nil, outsideProject: Bool? = nil,
                worktreePath: String? = nil, systemPermission: SystemPermissionNotice? = nil,
                connectorId: String? = nil, model: String? = nil, effort: String? = nil,
                autoApprove: Bool? = nil, diagnosis: FailureDiagnosis? = nil) {
        self.id = id
        self.agentId = agentId
        self.source = source
        self.title = title
        self.projectPath = projectPath
        self.projectName = projectName
        self.status = status
        self.lastMessage = lastMessage
        self.pendingRequest = pendingRequest
        self.origin = origin
        self.controllable = controllable
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.artifacts = artifacts
        self.outsideProject = outsideProject
        self.worktreePath = worktreePath
        self.systemPermission = systemPermission
        self.connectorId = connectorId
        self.model = model
        self.effort = effort
        self.autoApprove = autoApprove
        self.diagnosis = diagnosis
    }

    /// 会话实际的工作目录：在 worktree 里时是 worktree，否则就是项目路径。
    public var workingDirectory: String { worktreePath ?? projectPath }

    /// 这条任务属于哪个 Connector（分组、开关都按它）。两个枚举的原始值一一对应。
    public var connectorRef: ConnectorRef {
        ConnectorRef(kind: ConnectorKind(rawValue: source.rawValue) ?? .acp, id: connectorId)
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentId, source, title, projectPath, projectName, status, lastMessage, pendingRequest, origin
        case controllable, startedAt, updatedAt, artifacts, outsideProject, worktreePath, systemPermission, connectorId
        case model, effort, autoApprove, diagnosis
    }

    /// 字段照旧由合成的编码写出（nil 整键省略）；解码多一道校验：`connectorId` 只跟 `source = acp` 一起出现。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agentId = try container.decode(String.self, forKey: .agentId)
        source = try container.decode(TaskSource.self, forKey: .source)
        title = try container.decode(String.self, forKey: .title)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        projectName = try container.decode(String.self, forKey: .projectName)
        status = try container.decode(TaskStatus.self, forKey: .status)
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
        pendingRequest = try container.decodeIfPresent(PendingRequest.self, forKey: .pendingRequest)
        origin = try container.decode(TaskOrigin.self, forKey: .origin)
        controllable = try container.decode(Bool.self, forKey: .controllable)
        startedAt = try container.decode(String.self, forKey: .startedAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        artifacts = try container.decodeIfPresent([Artifact].self, forKey: .artifacts)
        outsideProject = try container.decodeIfPresent(Bool.self, forKey: .outsideProject)
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        systemPermission = try container.decodeIfPresent(SystemPermissionNotice.self, forKey: .systemPermission)
        connectorId = try container.decodeIfPresent(String.self, forKey: .connectorId)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        autoApprove = try container.decodeIfPresent(Bool.self, forKey: .autoApprove)
        diagnosis = try container.decodeIfPresent(FailureDiagnosis.self, forKey: .diagnosis)
        if let model, !ModelOption.isValidId(model) {
            throw DecodingError.dataCorruptedError(forKey: .model, in: container, debugDescription: "invalid model id")
        }
        if let effort, !ModelOption.isValidEffort(effort) {
            throw DecodingError.dataCorruptedError(forKey: .effort, in: container, debugDescription: "invalid effort")
        }
        if source == .acp {
            guard let connectorId, ConnectorRef.isValidAcpId(connectorId) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .connectorId, in: container, debugDescription: "source acp needs a valid connectorId")
            }
        } else if connectorId != nil {
            throw DecodingError.dataCorruptedError(
                forKey: .connectorId, in: container, debugDescription: "connectorId is only allowed for source acp")
        }
    }
}

/// ACP 任务的 id（协议 2.13）：`acp:<connectorId>:<sessionId>`。connectorId 不含冒号，
/// 所以按前两个冒号切；sessionId 本身可以带冒号。
public enum AcpTaskID {
    public static func make(connectorId: String, sessionId: String) -> String {
        "acp:\(connectorId):\(sessionId)"
    }

    public static func parse(_ taskId: String) -> (connectorId: String, sessionId: String)? {
        let parts = taskId.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == TaskSource.acp.rawValue,
              ConnectorRef.isValidAcpId(parts[1]), !parts[2].isEmpty else { return nil }
        return (parts[1], parts[2])
    }
}
