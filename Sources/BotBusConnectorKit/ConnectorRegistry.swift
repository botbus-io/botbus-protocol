import Foundation
import BotBusProtocol

/// 一次探测的结果：本机有没有这个 Connector，以及它当前健康到什么程度。
public struct ConnectorProbe: Hashable, Sendable {
    public var available: Bool
    public var status: ConnectorInfo.Status
    public var lastError: String?
    /// 能不能从手机新建任务（协议 2.13 的 `ConnectorInfo.canStartTask`，只报 false）。目前只有 DeepSeek Harness
    /// 会是 false：看得见电脑上的会话（web 或扫盘），但本机没有可执行文件起新会话。
    public var canStartTask: Bool

    public init(available: Bool, status: ConnectorInfo.Status, lastError: String? = nil, canStartTask: Bool = true) {
        self.available = available
        self.status = status
        self.lastError = lastError
        self.canStartTask = canStartTask
    }
}

/// 一个 Connector 的静态描述 + 探测方式。
///
/// 加第三个 Connector 的办法是在 `all(codexPaths:codexBinary:)` 的 switch 里加一个 case——
/// 那个 switch 对 `ConnectorKind` 穷举，新增枚举值会直接编译不过。其余调用方（`ConnectorRegistry`、
/// `TaskStore`、菜单栏、命令处理）一律遍历注册表给出的列表，不需要改一行。
public struct ConnectorDescriptor: Sendable {
    public var kind: ConnectorKind
    public var displayName: String
    /// 用户没表过态时的默认开关。探测不到的 Connector 默认关闭，免得菜单里挂一个永远报错的条目。
    public var defaultEnabled: Bool
    /// 本机没检测到时还要不要出现在 `AgentInfo.connectors` 里。Codex / Claude 一直报（"不可用"本身是信息）；
    /// 协议 2.5 的三个来源没装就不报——否则每台 Mac 在手机上都多挂三条永远"不可用"的条目。
    public var reportsWhenUnavailable: Bool
    public var probe: @Sendable () -> ConnectorProbe

    public init(kind: ConnectorKind, displayName: String, defaultEnabled: Bool,
                reportsWhenUnavailable: Bool = true,
                probe: @escaping @Sendable () -> ConnectorProbe) {
        self.kind = kind
        self.displayName = displayName
        self.defaultEnabled = defaultEnabled
        self.reportsWhenUnavailable = reportsWhenUnavailable
        self.probe = probe
    }
}

public extension ConnectorDescriptor {
    /// 不探测本机的描述符：每个一档 kind 一条，视为已装、已启用、状态 ok。`ConnectorRegistry()` 的默认值，
    /// 让 `TaskStore()` 这类不传注册表的调用（测试）看得到全部来源；真实探测在 BotBusConnectors 的 `all(...)`。
    static func placeholders() -> [ConnectorDescriptor] {
        ConnectorKind.allCases.compactMap { kind in
            guard kind != .acp else { return nil }
            return ConnectorDescriptor(kind: kind, displayName: kind.rawValue, defaultEnabled: true) {
                ConnectorProbe(available: true, status: .ok)
            }
        }
    }
}

/// 本机各 Connector 的探测结果与启用开关。
///
/// 是个加锁的 class 而不是 actor：`TaskStore`（actor）、菜单栏（`@MainActor`）与命令处理都要读它，
/// 同步 API 让三边都不用为了读一个布尔而跨隔离域 await，也就不存在 actor 重入带来的中间态。
public final class ConnectorRegistry: @unchecked Sendable {
    public static let displayNameLimit = 40
    public static let lastErrorLimit = 200

    private let lock = NSLock()
    private let descriptors: [ConnectorDescriptor]
    private var probes: [ConnectorKind: ConnectorProbe] = [:]
    private var enabled: [ConnectorKind: Bool] = [:]
    private var acpEntries: [AcpEntry] = []
    /// 协议 3.2：各连接器报给手机的可选模型。Codex 由 app-server 的 `model/list` 运行时写入，Claude 是固定的几个别名。
    private var models: [ConnectorKind: [ModelOption]] = [:]
    /// 用户对 ACP agent 表过的态；包括现在没发现到的（卸了重装还记得）。
    private var acpEnabled: [String: Bool]

    /// `enabled` 覆盖描述符的默认值（Task 8 从设置里读出来传进来）；没给的 kind 用 `defaultEnabled`。
    /// 一档描述符表在 BotBusConnectors 的 `ConnectorDescriptor.all(...)`，app 装配时一律传它。
    /// 不传时用 `ConnectorDescriptor.placeholders()`：全部一档 Connector 视为已装、已启用，给测试与不探测本机的调用方用。
    public init(descriptors: [ConnectorDescriptor] = ConnectorDescriptor.placeholders(),
                enabled overrides: [ConnectorKind: Bool] = [:],
                acpEnabled: [String: Bool] = [:]) {
        self.acpEnabled = acpEnabled
        // 同一 kind 只保留第一个描述符：AgentInfo 要求 connectors 按 kind 去重。
        var seen: Set<ConnectorKind> = []
        self.descriptors = descriptors.filter { seen.insert($0.kind).inserted }
        for descriptor in self.descriptors {
            enabled[descriptor.kind] = overrides[descriptor.kind] ?? descriptor.defaultEnabled
            probes[descriptor.kind] = descriptor.probe()
        }
    }

    /// 注册表里有描述符的 kind，按描述符顺序。
    public var kinds: [ConnectorKind] { descriptors.map(\.kind) }

    public func isEnabled(_ kind: ConnectorKind) -> Bool {
        // `acp` 这一层恒为开：每个 ACP agent 各有开关（`isAcpEnabled`），由 AcpHub 与 TaskStore 按 connectorId 判。
        if kind == .acp { return true }
        return lock.withLock { enabled[kind] ?? false }
    }

    public func isAvailable(_ kind: ConnectorKind) -> Bool {
        lock.withLock { kind == .acp ? !acpEntries.isEmpty : probes[kind]?.available ?? false }
    }

    /// 已启用的 kind，供调用方持久化。
    public var enabledKinds: Set<ConnectorKind> {
        lock.withLock { Set(enabled.filter(\.value).keys) }
    }

    /// 真的改了返回 true；值没变或 kind 不在注册表里返回 false（调用方据此决定要不要重发快照）。
    @discardableResult
    public func setEnabled(_ isEnabled: Bool, for kind: ConnectorKind) -> Bool {
        lock.withLock {
            guard let current = enabled[kind], current != isEnabled else { return false }
            enabled[kind] = isEnabled
            return true
        }
    }

    /// 重新探测一遍（设置里换了 Codex 目录、或者用户刚装上 ChatGPT.app 时调用）。
    public func refresh() {
        let fresh = descriptors.map { ($0.kind, $0.probe()) }
        lock.withLock {
            for (kind, probe) in fresh { probes[kind] = probe }
        }
    }

    /// 连接器运行时发现的问题（例如 OpenClaw Gateway 连不上）覆盖探测结果里的状态与错误，
    /// 下一次 `refresh()` 会重新以探测为准。kind 不在注册表里或本机不可用时不动。返回是否真的变了。
    @discardableResult
    public func reportRuntime(status: ConnectorInfo.Status, lastError: String?, for kind: ConnectorKind) -> Bool {
        lock.withLock {
            guard var probe = probes[kind], probe.available else { return false }
            guard probe.status != status || probe.lastError != lastError else { return false }
            probe.status = status
            probe.lastError = lastError
            probes[kind] = probe
            return true
        }
    }

    /// 协议 3.2：换一批可选模型（nil 或空 = 不能从手机换）。不合法的 id 与强度丢掉，重复的只留第一个，
    /// 超过 `ModelOption.maxModels` 的截掉——对端解码时这些都会让整份 AgentInfo 被拒。返回是否有变化。
    @discardableResult
    public func setModels(_ list: [ModelOption]?, for kind: ConnectorKind) -> Bool {
        let cleaned = Self.sanitized(list ?? [])
        return lock.withLock {
            guard models[kind] != cleaned else { return false }
            models[kind] = cleaned
            return true
        }
    }

    public func models(for kind: ConnectorKind) -> [ModelOption]? { lock.withLock { models[kind] } }

    public static func sanitized(_ list: [ModelOption]) -> [ModelOption]? {
        var seen: Set<String> = []
        let cleaned = list.compactMap { option -> ModelOption? in
            guard ModelOption.isValidId(option.id), seen.insert(option.id).inserted else { return nil }
            var efforts: [String] = []
            for effort in option.efforts ?? [] where ModelOption.isValidEffort(effort) && !efforts.contains(effort) {
                efforts.append(effort)
            }
            efforts = Array(efforts.prefix(ModelOption.maxEfforts))
            let name = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return ModelOption(id: option.id,
                               displayName: truncate(name.isEmpty ? option.id : name, limit: ModelOption.displayNameLimit),
                               efforts: efforts.isEmpty ? nil : efforts,
                               defaultEffort: option.defaultEffort.flatMap { efforts.contains($0) ? $0 : nil })
        }
        return cleaned.isEmpty ? nil : Array(cleaned.prefix(ModelOption.maxModels))
    }

    /// 一个 ACP agent 在注册表里的样子（协议 2.13）。由 `AcpHub` 按发现结果与运行时健康整批写入。
    public struct AcpEntry: Hashable, Sendable {
        public var id: String
        public var displayName: String
        public var defaultEnabled: Bool
        public var canStartTask: Bool
        public var status: ConnectorInfo.Status
        public var lastError: String?

        public init(id: String, displayName: String, defaultEnabled: Bool, canStartTask: Bool,
                    status: ConnectorInfo.Status, lastError: String?) {
            self.id = id
            self.displayName = displayName
            self.defaultEnabled = defaultEnabled
            self.canStartTask = canStartTask
            self.status = status
            self.lastError = lastError
        }
    }

    /// ACP agent 最多报这么多个：加上一档的总数不能超过 `AgentInfo.maxConnectors`。
    public var acpCapacity: Int { max(0, AgentInfo.maxConnectors - descriptors.count) }

    /// 换一批 ACP agent。超出容量的按显示名排序后丢掉（经反向扩展连进来时拒绝原因会说明）。返回是否有变化。
    @discardableResult
    public func setAcpEntries(_ entries: [AcpEntry]) -> Bool {
        let sorted = entries.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        let capped = Array(sorted.prefix(acpCapacity))
        return lock.withLock {
            guard capped != acpEntries else { return false }
            acpEntries = capped
            return true
        }
    }

    public var acpIds: [String] { lock.withLock { acpEntries.map(\.id) } }

    /// 注册表条目里这个 agent 的显示名（推送标题用）。不在条目里返回 nil。
    public func acpDisplayName(_ id: String) -> String? {
        lock.withLock { acpEntries.first { $0.id == id }?.displayName }
    }

    /// 没发现到的 id 一律当关：它的任务既不进快照，也不接命令。
    public func isAcpEnabled(_ id: String) -> Bool {
        lock.withLock {
            guard let entry = acpEntries.first(where: { $0.id == id }) else { return false }
            return acpEnabled[id] ?? entry.defaultEnabled
        }
    }

    @discardableResult
    public func setAcpEnabled(_ isEnabled: Bool, for id: String) -> Bool {
        lock.withLock {
            guard let entry = acpEntries.first(where: { $0.id == id }) else { return false }
            guard (acpEnabled[id] ?? entry.defaultEnabled) != isEnabled else { return false }
            acpEnabled[id] = isEnabled
            return true
        }
    }

    /// 供设置持久化。
    public var acpEnabledOverrides: [String: Bool] { lock.withLock { acpEnabled } }

    /// 上报给 Relay 的 `[ConnectorInfo]`。`taskCount` 由调用方（`TaskStore`）回填，没报数的算 0。一档照旧在前，
    /// ACP agent（按 `setAcpEntries` 定的显示名顺序）拼在末尾。
    public func connectors(taskCounts: [ConnectorRef: Int] = [:]) -> [ConnectorInfo] {
        let snapshot = lock.withLock { (probes, enabled, acpEntries, acpEnabled, models) }
        let builtins: [ConnectorInfo] = descriptors.compactMap { descriptor in
            let probe = snapshot.0[descriptor.kind] ?? ConnectorProbe(available: false, status: .degraded)
            guard probe.available || descriptor.reportsWhenUnavailable else { return nil }
            return ConnectorInfo(kind: descriptor.kind,
                                 displayName: Self.truncate(descriptor.displayName, limit: Self.displayNameLimit),
                                 available: probe.available,
                                 enabled: snapshot.1[descriptor.kind] ?? false,
                                 status: probe.status,
                                 taskCount: max(0, taskCounts[ConnectorRef(kind: descriptor.kind)] ?? 0),
                                 lastError: probe.lastError.map { Self.truncate($0, limit: Self.lastErrorLimit) },
                                 canStartTask: probe.canStartTask ? nil : false,
                                 // 本机没装时报了也选不了。
                                 models: probe.available ? snapshot.4[descriptor.kind] : nil,
                                 canAutoApprove: probe.available && descriptor.kind.supportsAutoApprove ? true : nil,
                                 canDeleteTasks: probe.available && [.codex, .claude].contains(descriptor.kind) ? true : nil)
        }
        let acp = snapshot.2.map { entry in
            ConnectorInfo(kind: .acp, connectorId: entry.id,
                          displayName: Self.truncate(entry.displayName, limit: Self.displayNameLimit),
                          available: true,
                          enabled: snapshot.3[entry.id] ?? entry.defaultEnabled,
                          status: entry.status,
                          taskCount: max(0, taskCounts[.acp(entry.id)] ?? 0),
                          lastError: entry.lastError.map { Self.truncate($0, limit: Self.lastErrorLimit) },
                          canStartTask: entry.canStartTask ? nil : false)
        }
        return builtins + acp
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }
}

public extension ConnectorKind {
    /// 任务来源与 Connector 一一对应（原始值相同）。将来出现没有任务来源的 Connector 时这里自然返回 nil。
    public var taskSource: TaskSource? { TaskSource(rawValue: rawValue) }

    public init?(_ source: TaskSource) {
        self.init(rawValue: source.rawValue)
    }

    /// 这个来源能不能收手机发的图（协议 2.9）。只有 Codex 与 Claude Code 能把图交给模型；
    /// 与 ClientCore 的 `TaskSource.acceptsImages` 保持一致（手机据那边决定给不给选图按钮）。
    /// 分发器据此在下载之前就拒掉，不白下一趟图；连接器自己的同一道检查留着兜底。
    public var acceptsImages: Bool {
        switch self {
        case .codex, .claude: true
        // DeepSeek Harness 的 ACP 握手里 `promptCapabilities.image` 为 false。
        case .hermes, .pi, .openclaw, .dsh: false
        // ACP：能不能收图要跟 agent 握手后才知道，这里先放行，由连接器那道检查兜底。
        case .acp: true
        }
    }

    /// 这个来源支不支持项目级自动批准（协议 3.3 的 `ConnectorInfo.canAutoApprove`）：Agent 替手机跑的轮次里
    /// 遇到审批能不能直接放行。Codex（app-server 的审批请求）与 Claude Code（`PermissionRequest` hook）能；
    /// 其余要么没有审批通道，要么审批带着自己的范围选项，不报。分发器据此拒掉带 `autoApprove` 的命令。
    public var supportsAutoApprove: Bool {
        switch self {
        case .codex, .claude: true
        case .hermes, .pi, .openclaw, .dsh, .acp: false
        }
    }
}
