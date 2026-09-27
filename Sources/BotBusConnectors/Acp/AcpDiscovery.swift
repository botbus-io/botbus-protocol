import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 发现到的一个 ACP agent：怎么启动、叫什么、从哪儿来。
public struct AcpAgentSpec: Hashable, Sendable {
    public enum Origin: String, Hashable, Sendable { case manifest, registry }

    public var id: String
    public var name: String
    /// 可执行文件的绝对路径。nil = 清单没写 `command`，只能经反向扩展接入。
    public var executable: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var origin: Origin
    public var defaultEnabled: Bool

    public init(id: String, name: String, executable: String?, arguments: [String], environment: [String: String],
                origin: Origin, defaultEnabled: Bool) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.origin = origin
        self.defaultEnabled = defaultEnabled
    }
}

/// `~/.botbus/agents/<id>.json`（spec「发现」）。
public struct AcpManifest: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
}

/// 内置注册表快照里的一条（由 `scripts/acp-registry-snapshot.py` 生成，见 `AcpRegistrySnapshot`）。
public struct AcpRegistryEntry: Hashable, Sendable {
    public var id: String
    public var name: String
    /// 本机可能的可执行文件名，按顺序找。
    public var binaries: [String]
    public var args: [String]
    public var defaultEnabled: Bool
    /// npm 包名（含 `@scope/`，不含版本号）；只有 `npx` 分发的条目才有值。
    /// 有值时按名字找到的可执行文件必须真实落在这个包的 `node_modules/` 目录下才采信，
    /// 防止同名的无关本机程序被当成这个 agent 启动（`binary` / `uvx` 分发没有这一步，
    /// 靠后续任务加的「第一次 ACP 握手失败就隐藏」兜底）。
    public var npmPackage: String?
    /// 注册表登记的官网（只收 https）。设置窗口「支持的 Agent」页点「下载」打开它，不参与发现。
    public var website: URL?

    public init(id: String, name: String, binaries: [String], args: [String], defaultEnabled: Bool,
                npmPackage: String? = nil, website: String? = nil) {
        self.id = id
        self.name = name
        self.binaries = binaries
        self.args = args
        self.defaultEnabled = defaultEnabled
        self.npmPackage = npmPackage
        self.website = website.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
    }
}

/// 一份坏掉的清单：菜单里单独列出来，告诉开发者哪个文件、错在哪。
public struct AcpManifestProblem: Hashable, Sendable, Error {
    public var file: String
    public var reason: String

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

public struct AcpDiscoveryResult: Hashable, Sendable {
    public var agents: [AcpAgentSpec]
    public var problems: [AcpManifestProblem]

    public init(agents: [AcpAgentSpec], problems: [AcpManifestProblem]) {
        self.agents = agents
        self.problems = problems
    }
}

/// 找本机的 ACP agent：约定目录优先，其次内置注册表快照(spec「合并规则」：一档 > 约定目录 > 注册表)。
/// 只读文件、只查可执行文件在不在，**不起进程**。
public enum AcpDiscovery {
    public static var defaultManifestDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".botbus/agents", isDirectory: true)
    }

    /// 一档已经深度适配的：注册表里对应它们的适配器直接跳过，约定目录里也不许用这些 id。
    public static let reservedIds: Set<String> = Set(ConnectorKind.allCases.map(\.rawValue))
        .union(["claude-acp", "codex-acp", "pi-acp"])

    public static func discover(manifestDirectory: URL = defaultManifestDirectory,
                                catalog: [AcpRegistryEntry] = AcpRegistrySnapshot.entries,
                                locate: (String) -> String? = { AgentBinary.detect($0) },
                                fileManager: FileManager = .default) -> AcpDiscoveryResult {
        var problems: [AcpManifestProblem] = []
        var byId: [String: AcpAgentSpec] = [:]
        let files = ((try? fileManager.contentsOfDirectory(at: manifestDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            switch loadManifest(file, locate: locate, fileManager: fileManager) {
            case .success(let spec):
                if reservedIds.contains(spec.id) {
                    problems.append(AcpManifestProblem(file: file.path, reason: "id「\(spec.id)」已被 BotBus 内置的 agent 占用，换一个"))
                } else {
                    byId[spec.id] = spec
                }
            case .failure(let problem):
                problems.append(problem)
            }
        }
        for entry in catalog where byId[entry.id] == nil && !reservedIds.contains(entry.id) {
            guard let executable = locateVerifiedBinary(for: entry, locate: locate) else { continue }
            byId[entry.id] = AcpAgentSpec(id: entry.id, name: entry.name, executable: executable, arguments: entry.args,
                                          environment: [:], origin: .registry, defaultEnabled: entry.defaultEnabled)
        }
        // `byId.values` 的迭代顺序按进程随机的哈希种子来，每次启动都可能不一样；
        // 名字相同时按 id 兜底，保证顺序在多次启动之间稳定。
        let agents = byId.values.sorted {
            let byName = $0.name.localizedStandardCompare($1.name)
            return byName == .orderedSame ? $0.id < $1.id : byName == .orderedAscending
        }
        return AcpDiscoveryResult(agents: agents, problems: problems)
    }

    /// 按 `entry.binaries` 顺序找一个可执行文件。
    ///
    /// `npmPackage` 有值时（`npx` 分发）：只按名字定位还不够——PATH 上可能装着同名的无关程序
    /// （`nova` 的 npm 包里那个可执行文件叫 `compass`，同名的 Sass 老工具也叫这个），所以还要求
    /// 解出的真实路径（跟软链接）落在 `node_modules/<npmPackage>/` 下；不满足就试下一个候选名，
    /// 都不满足就跳过这个 agent，不猜。
    ///
    /// 没有 `npmPackage` 的（`binary` / `uvx` 分发）没有类似的本机验证手段，仍只按名字命中；
    /// 这类的验证留给后续任务：第一次 ACP 握手失败就把这个 agent 从列表里隐藏。
    static func locateVerifiedBinary(for entry: AcpRegistryEntry, locate: (String) -> String?) -> String? {
        guard let npmPackage = entry.npmPackage else {
            return entry.binaries.lazy.compactMap(locate).first
        }
        let marker = "/node_modules/\(npmPackage)/"
        for name in entry.binaries {
            guard let located = locate(name) else { continue }
            let resolved = URL(fileURLWithPath: located).resolvingSymlinksInPath().path
            if resolved.contains(marker) { return located }
        }
        return nil
    }

    static func loadManifest(_ file: URL, locate: (String) -> String?,
                             fileManager: FileManager) -> Result<AcpAgentSpec, AcpManifestProblem> {
        func problem(_ reason: String) -> Result<AcpAgentSpec, AcpManifestProblem> {
            .failure(AcpManifestProblem(file: file.path, reason: reason))
        }
        guard let data = fileManager.contents(atPath: file.path) else { return problem("读不了这个文件") }
        guard let manifest = try? JSONDecoder().decode(AcpManifest.self, from: data) else {
            return problem("不是合法的清单 JSON（至少要有 id 和 name）")
        }
        guard ConnectorRef.isValidAcpId(manifest.id) else {
            return problem("id 只能用小写字母、数字和 -，最多 \(ConnectorRef.maxAcpIdLength) 个字符")
        }
        guard file.deletingPathExtension().lastPathComponent == manifest.id else {
            return problem("文件名必须是 \(manifest.id).json")
        }
        let name = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return problem("name 不能为空") }

        var executable: String?
        if let raw = manifest.command?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let command = (raw as NSString).expandingTildeInPath
            if command.hasPrefix("/") {
                guard fileManager.isExecutableFile(atPath: command) else {
                    return problem("command 指向的文件不存在或不可执行：\(command)")
                }
                executable = command
            } else {
                guard let found = locate(command) else { return problem("找不到 command：\(command)") }
                executable = found
            }
        }
        return .success(AcpAgentSpec(id: manifest.id, name: String(name.prefix(ConnectorRegistry.displayNameLimit)),
                                     executable: executable, arguments: manifest.args ?? [],
                                     environment: manifest.env ?? [:], origin: .manifest, defaultEnabled: true))
    }
}
