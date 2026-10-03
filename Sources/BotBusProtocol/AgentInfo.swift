import Foundation

/// 一台电脑上的一个 AI agent。协议 2.5 起加入 `hermes`、`pi`、`openclaw`；2.13 起加入 `acp`（所有 ACP agent 共用，
/// 用 `connectorId` 区分）；3.1 起加入 `dsh`（DeepSeek Harness，一档）。遇未知值必须拒绝整条（不回落默认值）。
public enum ConnectorKind: String, Codable, Sendable, CaseIterable {
    case codex, claude, hermes, pi, openclaw, acp, dsh
}

/// Agent 所在平台（协议 3.5 起加入 `linux`、`windows`）。未知值解码为 `.other`，三端不因新平台拒收整份快照。
public enum AgentPlatform: RawRepresentable, Codable, Sendable, Hashable {
    case macos
    case linux
    case windows
    /// Future platform not yet known to this build.
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "macos": self = .macos
        case "linux": self = .linux
        case "windows": self = .windows
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .macos: "macos"
        case .linux: "linux"
        case .windows: "windows"
        case .other(let v): v
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 同一台电脑上一个 Connector 的身份（协议 2.13）：一档 agent 只有 kind；ACP agent 是 `kind = acp` 加上 connectorId。
/// 不是线上类型，是三端共用的标识——分组、tab、开关、去重都按它。
public struct ConnectorRef: Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let maxAcpIdLength = 32

    public var kind: ConnectorKind
    /// 只有 `kind = acp` 时才有值；其余 kind 传进来也会被丢掉。
    public var id: String?

    public init(kind: ConnectorKind, id: String? = nil) {
        self.kind = kind
        self.id = kind == .acp ? id : nil
    }

    public static func acp(_ id: String) -> ConnectorRef { ConnectorRef(kind: .acp, id: id) }

    /// `codex`、`claude`…；ACP 是 `acp:<id>`。可以存进 UserDefaults / `@AppStorage`，再用 `init?(_:)` 读回来。
    public var description: String { id.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue }

    public init?(_ description: String) {
        let parts = description.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let kind = ConnectorKind(rawValue: parts[0]) else { return nil }
        if kind == .acp {
            guard parts.count == 2, Self.isValidAcpId(parts[1]) else { return nil }
            self.init(kind: .acp, id: parts[1])
        } else {
            guard parts.count == 1 else { return nil }
            self.init(kind: kind)
        }
    }

    public static func < (lhs: ConnectorRef, rhs: ConnectorRef) -> Bool { lhs.description < rhs.description }

    /// ACP agent 的 id：`[a-z0-9-]`，1–32 个字符。不含冒号，所以 `acp:<id>:<sessionId>` 能唯一切开。
    public static func isValidAcpId(_ id: String) -> Bool {
        guard (1...maxAcpIdLength).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
        }
    }
}

/// 一台电脑上某个 Connector 的状态，由该电脑的 Agent 上报。
public struct ConnectorInfo: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable, CaseIterable { case ok, degraded, error }

    /// 同一台电脑上 `(kind, connectorId)` 唯一（协议 2.13），可直接当列表标识。
    public var id: ConnectorRef { ref }
    public var ref: ConnectorRef { ConnectorRef(kind: kind, id: connectorId) }

    public var kind: ConnectorKind
    /// 协议 2.13：ACP agent 的 id（清单或注册表里的 id）。`kind = acp` 时必填，其余 kind 省略。
    public var connectorId: String?
    public var displayName: String
    public var available: Bool
    public var enabled: Bool
    public var status: Status
    public var taskCount: Int
    public var lastError: String?
    /// 协议 2.13：能不能从手机新建任务。只写 false，能的时候整个键省略。
    public var canStartTask: Bool?
    /// 协议 3.2：手机续聊时能换的模型，电脑自己排好序（默认的那个在前）。省略 = 这个 agent 不能从手机换模型；
    /// 有它时不是空数组，最多 `ModelOption.maxModels` 个、按 `id` 不重复。
    public var models: [ModelOption]?
    /// 协议 3.3：能不能给项目开「自动批准」（手机发起的轮次里审批不再逐条问）。只写 true，不能时整个键省略。
    public var canAutoApprove: Bool?

    public init(kind: ConnectorKind, connectorId: String? = nil, displayName: String, available: Bool, enabled: Bool,
                status: Status, taskCount: Int, lastError: String? = nil, canStartTask: Bool? = nil,
                models: [ModelOption]? = nil, canAutoApprove: Bool? = nil) {
        self.kind = kind
        self.connectorId = connectorId
        self.displayName = displayName
        self.available = available
        self.enabled = enabled
        self.status = status
        self.taskCount = taskCount
        self.lastError = lastError
        self.canStartTask = canStartTask
        self.models = models
        self.canAutoApprove = canAutoApprove
    }

    private enum CodingKeys: String, CodingKey {
        case kind, connectorId, displayName, available, enabled, status, taskCount, lastError, canStartTask, models
        case canAutoApprove
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ConnectorKind.self, forKey: .kind)
        connectorId = try container.decodeIfPresent(String.self, forKey: .connectorId)
        displayName = try container.decode(String.self, forKey: .displayName)
        available = try container.decode(Bool.self, forKey: .available)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        status = try container.decode(Status.self, forKey: .status)
        taskCount = try container.decode(Int.self, forKey: .taskCount)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        canStartTask = try container.decodeIfPresent(Bool.self, forKey: .canStartTask)
        models = try container.decodeIfPresent([ModelOption].self, forKey: .models)
        canAutoApprove = try container.decodeIfPresent(Bool.self, forKey: .canAutoApprove)

        if let models {
            guard !models.isEmpty, models.count <= ModelOption.maxModels,
                  Set(models.map(\.id)).count == models.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .models, in: container,
                    debugDescription: "models must be 1...\(ModelOption.maxModels) entries, unique by id")
            }
        }
        guard taskCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .taskCount, in: container,
                debugDescription: "taskCount must be >= 0, got \(taskCount)")
        }
        if kind == .acp {
            guard let connectorId, ConnectorRef.isValidAcpId(connectorId) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .connectorId, in: container, debugDescription: "kind acp needs a valid connectorId")
            }
        } else if connectorId != nil {
            throw DecodingError.dataCorruptedError(
                forKey: .connectorId, in: container, debugDescription: "connectorId is only allowed for kind acp")
        }
    }
}

/// 协议 3.2：手机上能选的一个模型，以及它支持的思考强度。
///
/// `id` 原样回到 `Command.FollowUp.model`，由电脑交给 agent（Codex 的 `turn/start.model`、Claude 的 `--model`）；
/// 思考强度同理（`effort` / `--effort`）。强度是 agent 自己的词（`low`、`medium`、`high`、`xhigh`、`max`…），
/// 协议不定闭集，客户端认得的翻成中文，不认得的原样显示。
public struct ModelOption: Codable, Hashable, Sendable, Identifiable {
    public static let maxModels = 24
    public static let maxEfforts = 8
    public static let maxIdLength = 64
    public static let maxEffortLength = 16
    public static let displayNameLimit = 40

    public var id: String
    public var displayName: String
    /// 能选的思考强度，从低到高。省略 = 这个模型不能调强度（有它时不是空数组）。
    public var efforts: [String]?
    /// agent 在没指定强度时用哪一档；必须是 `efforts` 里的一个。
    public var defaultEffort: String?

    public init(id: String, displayName: String, efforts: [String]? = nil, defaultEffort: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }

    private enum CodingKeys: String, CodingKey { case id, displayName, efforts, defaultEffort }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        efforts = try container.decodeIfPresent([String].self, forKey: .efforts)
        defaultEffort = try container.decodeIfPresent(String.self, forKey: .defaultEffort)
        guard Self.isValidId(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "invalid model id")
        }
        if let efforts {
            guard !efforts.isEmpty, efforts.count <= Self.maxEfforts, Set(efforts).count == efforts.count,
                  efforts.allSatisfy(Self.isValidEffort) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .efforts, in: container, debugDescription: "efforts must be 1...\(Self.maxEfforts) valid, unique values")
            }
        }
        if let defaultEffort, efforts?.contains(defaultEffort) != true {
            throw DecodingError.dataCorruptedError(
                forKey: .defaultEffort, in: container, debugDescription: "defaultEffort must be one of efforts")
        }
    }

    /// 模型 id：1–64 个 `[A-Za-z0-9._:/-]`，不以 `-` 开头——它会成为 agent 命令行的一个参数值，
    /// 以 `-` 开头会被当成另一个选项。
    public static func isValidId(_ id: String) -> Bool {
        guard (1...maxIdLength).contains(id.count), !id.hasPrefix("-") else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || "._:/-".unicodeScalars.contains(scalar)
        }
    }

    /// 思考强度：1–16 个 `[a-z0-9-]`，不以 `-` 开头。
    public static func isValidEffort(_ effort: String) -> Bool {
        guard (1...maxEffortLength).contains(effort.count), !effort.hasPrefix("-") else { return false }
        return effort.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
        }
    }
}

/// 协议 3.5：宿主（电脑这一端）的能力。每个键都是可选布尔，**缺省 = 支持**：现在的 Mac 整个对象都不报；
/// Linux 宿主首版报 `remoteControl: false`（手机不给「电脑屏幕」入口）与 `previews: false`（手机不显示预览）。
/// 不认得的键一律忽略（以后加能力不用发手机版）；`false` 表示不支持，`true` 与省略同义。
public struct HostCapabilities: Codable, Sendable, Hashable {
    /// 远程操作电脑屏幕（`remoteControl` 命令、自动开的远程操作预览）。
    public var remoteControl: Bool?
    /// 把本机端口分享成预览（`preview` 产物）。
    public var previews: Bool?
    /// 按需取回对话里提到的文件（`fetchFile` 命令）。
    public var fetchFile: Bool?
    /// 看未提交的改动（`fetchChanges` 命令）。
    public var fetchChanges: Bool?

    public init(remoteControl: Bool? = nil, previews: Bool? = nil, fetchFile: Bool? = nil, fetchChanges: Bool? = nil) {
        self.remoteControl = remoteControl
        self.previews = previews
        self.fetchFile = fetchFile
        self.fetchChanges = fetchChanges
    }

    /// 缺省（nil）= 支持。
    public var supportsRemoteControl: Bool { remoteControl ?? true }
    public var supportsPreviews: Bool { previews ?? true }
    public var supportsFetchFile: Bool { fetchFile ?? true }
    public var supportsFetchChanges: Bool { fetchChanges ?? true }
}

/// 一台已配对的电脑。`online` 与 `lastSeenAt` 由 Relay 按连接状态维护，Agent 上报时分别填 true 与当前时间。
public struct AgentInfo: Codable, Hashable, Sendable, Identifiable {
    /// 一台电脑最多挂这么多 Connector：一档 6 个 + ACP 最多 10 个；空数组是合法的（刚被认领、还没连上过的电脑）。
    public static let maxConnectors = 16

    public var id: String { agentId }

    public var agentId: String
    public var name: String
    public var platform: AgentPlatform
    public var online: Bool
    public var lastSeenAt: String
    public var appVersion: String
    public var connectors: [ConnectorInfo]
    /// 协议 2.6：手机上新建项目时，电脑在这个目录下建子文件夹（绝对路径）。nil = 这台电脑不接受新建项目。
    public var projectsRoot: String?
    /// 协议 3.4：这台电脑能从手机开 worktree 会话（`startTask.worktree`）、能 `mergeWorktree`。只写 true，nil = 不能。
    public var worktrees: Bool?
    /// 协议 3.5：宿主能力，见 `HostCapabilities`。nil = 全部支持（现在的 Mac）。
    public var capabilities: HostCapabilities?
    /// 协议 3.7：这台电脑提供「操作电脑」的工作区服务（文件，之后是终端），`remoteControl` 命令在没有屏幕的宿主上也能用。
    /// 只写 true，nil = 没有。不放进 `HostCapabilities`：那里「省略 = 支持」，什么都不报的旧电脑会被当成有。
    public var workspace: Bool?

    public init(agentId: String, name: String, platform: AgentPlatform = .macos, online: Bool,
                lastSeenAt: String, appVersion: String, connectors: [ConnectorInfo], projectsRoot: String? = nil,
                worktrees: Bool? = nil, capabilities: HostCapabilities? = nil, workspace: Bool? = nil) {
        self.agentId = agentId
        self.name = name
        self.platform = platform
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.appVersion = appVersion
        self.connectors = connectors
        self.projectsRoot = projectsRoot
        self.worktrees = worktrees
        self.capabilities = capabilities
        self.workspace = workspace
    }

    private enum CodingKeys: String, CodingKey {
        case agentId, name, platform, online, lastSeenAt, appVersion, connectors, projectsRoot, worktrees, capabilities
        case workspace
    }

    /// 校验集中在这里：Connector 最多 16 个且按 (kind, connectorId) 去重。数量下限没有——空数组合法。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try container.decode(String.self, forKey: .agentId)
        name = try container.decode(String.self, forKey: .name)
        platform = try container.decode(AgentPlatform.self, forKey: .platform)
        online = try container.decode(Bool.self, forKey: .online)
        lastSeenAt = try container.decode(String.self, forKey: .lastSeenAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        connectors = try container.decode([ConnectorInfo].self, forKey: .connectors)
        projectsRoot = try container.decodeIfPresent(String.self, forKey: .projectsRoot)
        worktrees = try container.decodeIfPresent(Bool.self, forKey: .worktrees)
        capabilities = try container.decodeIfPresent(HostCapabilities.self, forKey: .capabilities)
        workspace = try container.decodeIfPresent(Bool.self, forKey: .workspace)

        guard connectors.count <= Self.maxConnectors else {
            throw DecodingError.dataCorruptedError(
                forKey: .connectors, in: container,
                debugDescription: "at most \(Self.maxConnectors) connectors, got \(connectors.count)")
        }
        guard Set(connectors.map(\.ref)).count == connectors.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .connectors, in: container,
                debugDescription: "connectors must be unique by (kind, connectorId)")
        }
        if worktrees == false {
            throw DecodingError.dataCorruptedError(forKey: .worktrees, in: container,
                                                   debugDescription: "worktrees is only written as true")
        }
        if workspace == false {
            throw DecodingError.dataCorruptedError(forKey: .workspace, in: container,
                                                   debugDescription: "workspace is only written as true")
        }
    }
}
