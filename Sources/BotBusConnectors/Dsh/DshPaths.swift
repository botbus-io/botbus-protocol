import Foundation
import BotBusConnectorKit

/// DeepSeek Harness（`@deepseek-ai/dsh`，协议 3.1）的本机目录与可执行文件。
///
/// 主目录固定 `~/.dsh`：同 `AgentBinary`，GUI 进程读不到用户 shell 里的 `DSH_HOME`，所以不认它
///（测试注入 `home`）。子进程一律显式带上 `DSH_HOME = home`，不让继承来的环境变量把 dsh 指到别处。
///
/// 目录布局（dsh 0.1.5-rc.3 实测，见 spec）：
/// - `sessions/--<规范化 cwd>--/<sessionId>/session.v3.jsonl.zstd`（多个 zstd 帧首尾拼接）与 `session.lock`；
/// - `storages/session_projcache/sessions/<sessionId>.json`：明文投影缓存（标题、轮次边界、列表元数据）；
/// - `.credentials.yaml`（0600）：只许读其中 web cookie 的签名密钥，见 `DshWebCredentials`。
public struct DshPaths: Sendable {
    /// 一档来源的 id，也是 `AcpConnector` 的 spec id 与本机记录的键。
    public static let agentId = "dsh"
    public static let displayName = "DeepSeek Harness"
    public static let npmPackage = "@deepseek-ai/dsh"
    /// 解 transcript 要 `zlib.zstdDecompressSync`：Node 22.15 / 23.8 起才有。挑 node 时低于它的不要。
    public static let minimumNodeVersion = DshVersion(major: 22, minor: 15, patch: 0)

    public var home: URL

    public init(home: URL = DshPaths.defaultHome) {
        self.home = home
    }

    public static var defaultHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh", isDirectory: true)
    }

    public var sessionsDirectory: URL { home.appendingPathComponent("sessions", isDirectory: true) }

    public var projectionCacheDirectory: URL {
        home.appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
    }

    public var credentialsFile: URL { home.appendingPathComponent(".credentials.yaml") }

    public func projectionCacheFile(sessionId: String) -> URL {
        projectionCacheDirectory.appendingPathComponent("\(sessionId).json")
    }

    public func hasSessionsDirectory(fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: sessionsDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// 算"装了"：找得到可执行文件，或者 `sessions/` 在（只读也能看）。都没有就不上报这个来源。
    public func isInstalled(_ installation: DshInstallation?, fileManager: FileManager = .default) -> Bool {
        installation != nil || hasSessionsDirectory(fileManager: fileManager)
    }

    /// 子进程环境里要叠上的：只有 `DSH_HOME`。
    public var environment: [String: String] { ["DSH_HOME": home.path] }
}

/// 找到的 dsh 怎么起。
public struct DshInstallation: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// PATH 类目录里的 `dsh`（npm 全局装的 `#!/usr/bin/env node` 脚本，或别的包装）。
        case binary
        /// 只在 npx 缓存里：`<node> <package>/lib/bin.js`。
        case npxCache
    }

    public var kind: Kind
    /// 要执行的文件：`.binary` 是 dsh 本身，`.npxCache` 是 node。
    public var executable: String
    /// 放在子命令之前的参数：`.npxCache` 是 `[<package>/lib/bin.js]`，`.binary` 为空。
    public var leadingArguments: [String]
    /// npx 包或桌面 app 的版本；普通 PATH 包装器不读，为 nil。
    public var version: String?
    /// 跑内嵌 node 脚本（解 transcript）用的 node；找不到够新的就是 nil，那时只能靠 web 读记录。
    public var node: String?

    public init(kind: Kind, executable: String, leadingArguments: [String], version: String?, node: String?) {
        self.kind = kind
        self.executable = executable
        self.leadingArguments = leadingArguments
        self.version = version
        self.node = node
    }

    /// `dsh --profile acp` 的完整参数。
    public var acpArguments: [String] { leadingArguments + ["--profile", "acp"] }

    /// 给 `AcpConnector` 用的 spec（id `dsh`）。`environment` 只叠 `DSH_HOME`；PATH 由 `AcpConnector.ensureRunning`
    /// 经 `AgentBinary.environment(for: executable)` 把可执行文件（dsh 脚本或 node）所在目录放到最前。
    /// `origin` 只在 `AcpHub` 里有意义（注册表 agent 握手失败会被藏），一档连接器不经 hub，这里随便填 `.manifest`。
    public func acpSpec(paths: DshPaths) -> AcpAgentSpec {
        AcpAgentSpec(id: DshPaths.agentId, name: DshPaths.displayName, executable: executable,
                     arguments: acpArguments, environment: paths.environment, origin: .manifest, defaultEnabled: true)
    }
}

extension DshPaths {
    /// 本机的 dsh：优先桌面版随包 CLI（与桌面日志版本一致），再 `AgentBinary.detect("dsh")`，最后 npx 缓存。
    /// 会读盘，`.binary` 时还可能跑几次 `node --version`（挑 node），别在主线程上反复调。
    ///
    /// - Parameters:
    ///   - locate: 找 PATH 类目录里的可执行文件（测试注入）。
    ///   - npxRoot: npx 缓存根（`~/.npm/_npx`）。
    ///   - desktopBundles: 候选桌面 app；测试传空数组，不读取本机安装。
    ///   - nodeVersion: 问一个 node 的版本（测试注入；默认跑 `<node> --version`，3 秒超时）。
    public static func detectInstallation(
        locate: (String) -> String? = { AgentBinary.detect($0) },
        npxRoot: URL = defaultNpxRoot,
        desktopBundles: [URL] = defaultDesktopBundles,
        nodeCandidates: [String] = defaultNodeCandidates(),
        nodeVersion: (String) -> DshVersion? = cachedNodeVersion,
        fileManager: FileManager = .default
    ) -> DshInstallation? {
        if !desktopBundles.isEmpty,
           let desktop = DshDesktopInstallation.detect(bundles: desktopBundles,
               node: selectNode(from: nodeCandidates, version: nodeVersion, fileManager: fileManager), fileManager: fileManager) {
            return desktop
        }
        if let binary = locate("dsh") {
            // 脚本旁边的 node 优先（npm 全局装时几乎总在同一个 bin 目录），再按常见位置找。
            let beside = AgentBinary.pathDirectories(for: binary).map { ($0 as NSString).appendingPathComponent("node") }
            let node = selectNode(from: beside + nodeCandidates, version: nodeVersion, fileManager: fileManager)
            return DshInstallation(kind: .binary, executable: binary, leadingArguments: [], version: nil, node: node)
        }
        guard let package = newestNpxPackage(npxRoot: npxRoot, fileManager: fileManager),
              let node = selectNode(from: nodeCandidates, version: nodeVersion, fileManager: fileManager) else {
            return nil
        }
        let script = package.directory.appendingPathComponent("lib/bin.js").path
        return DshInstallation(kind: .npxCache, executable: node, leadingArguments: [script],
                               version: package.version.description, node: node)
    }

    public static var defaultNpxRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx", isDirectory: true)
    }

    public static var defaultDesktopBundles: [URL] { DshDesktopInstallation.defaultBundles }

    /// npx 缓存里的一份 dsh 包。
    public struct NpxPackage: Hashable, Sendable {
        public var directory: URL
        public var version: DshVersion
    }

    /// `<npxRoot>/*/node_modules/@deepseek-ai/dsh/package.json` 里版本最高、且 `lib/bin.js` 在的那份。
    /// 版本号解析不了的跳过；同版本多份时取目录名排序靠前的（结果稳定即可）。
    public static func newestNpxPackage(npxRoot: URL, fileManager: FileManager = .default) -> NpxPackage? {
        guard let hashes = try? fileManager.contentsOfDirectory(atPath: npxRoot.path) else { return nil }
        var best: NpxPackage?
        for hash in hashes.sorted() {
            let directory = npxRoot.appendingPathComponent(hash, isDirectory: true)
                .appendingPathComponent("node_modules/@deepseek-ai/dsh", isDirectory: true)
            let manifest = directory.appendingPathComponent("package.json")
            guard let data = try? Data(contentsOf: manifest),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["name"] as? String == npmPackage,
                  let text = object["version"] as? String, let version = DshVersion(text),
                  fileManager.fileExists(atPath: directory.appendingPathComponent("lib/bin.js").path) else { continue }
            if best.map({ version > $0.version }) ?? true { best = NpxPackage(directory: directory, version: version) }
        }
        return best
    }

    /// 候选 node：与 `AgentBinary.detect` 同一组目录（常见 bin 目录在前，nvm 新版本在前）。
    public static func defaultNodeCandidates(fileManager: FileManager = .default) -> [String] {
        (AgentBinary.commonDirectories + AgentBinary.nvmBinDirectories(fileManager: fileManager))
            .map { (($0 as NSString).expandingTildeInPath as NSString).appendingPathComponent("node") }
    }

    /// 按顺序挑第一个可执行、版本 ≥ `minimumNodeVersion` 的 node（软链接解开后去重，同一个文件只问一次版本）。
    public static func selectNode(from candidates: [String], version: (String) -> DshVersion?,
                                  fileManager: FileManager = .default) -> String? {
        var seen: Set<String> = []
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            let resolved = (candidate as NSString).resolvingSymlinksInPath
            guard seen.insert(resolved).inserted else { continue }
            if let found = version(candidate), found >= minimumNodeVersion { return candidate }
        }
        return nil
    }

    /// 同 `probeNodeVersion`，按"解开软链接后的路径 + 修改时间"记住结果：`detectInstallation` 每次重新探测都要挑 node，
    /// 注册表每次 `refresh()` 都会跑一遍，不能每次都起几个 node 进程。node 换了版本（文件变了）就重新问。
    public static let cachedNodeVersion: @Sendable (String) -> DshVersion? = { node in
        let resolved = (node as NSString).resolvingSymlinksInPath
        let modified = (try? FileManager.default.attributesOfItem(atPath: resolved))?[.modificationDate] as? Date
        let key = "\(resolved)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let hit = nodeVersionMemo.withLock({ $0[key] }) { return hit }
        let version = probeNodeVersion(node)
        nodeVersionMemo.withLock { $0[key] = .some(version) }
        return version
    }

    private static let nodeVersionMemo = LockedValue<[String: DshVersion?]>([:])

    /// 跑 `<node> --version`（`v24.1.0`），3 秒超时。失败返回 nil。
    public static let probeNodeVersion: @Sendable (String) -> DshVersion? = { node in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--version"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            return nil
        }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        // 读完就关：Linux 的 Foundation 不会在 EOF 时替你关读端。
        try? stdout.fileHandleForReading.close()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return DshVersion(text.hasPrefix("v") ? String(text.dropFirst()) : text)
    }
}

/// 本机 dsh 装在哪的缓存：探测会读 npx 缓存、可能还要问 node 的版本，不能在每次用到时都跑一遍。
///
/// `current()` 给上一次的结果（第一次调用时才探测）；`refresh()` 重新探测，由 `ConnectorRegistry.refresh()`
/// 经描述符的探测闭包触发（设置里改了东西、用户刚装上 dsh 之类）。连接器与描述符共用一个实例，看到的是同一份结果。
public final class DshInstallationProbe: @unchecked Sendable {
    /// 描述符的默认值（`ConnectorDescriptor.all()` 不传时）共用这一个。
    public static let shared = DshInstallationProbe()

    private let lock = NSLock()
    private var cached: DshInstallation??
    private let detect: @Sendable () -> DshInstallation?

    public init(detect: @escaping @Sendable () -> DshInstallation? = { DshPaths.detectInstallation() }) {
        self.detect = detect
    }

    public func current() -> DshInstallation? {
        if let cached = lock.withLock({ cached }) { return cached }
        return refresh()
    }

    @discardableResult
    public func refresh() -> DshInstallation? {
        let found = detect()
        lock.withLock { cached = .some(found) }
        return found
    }
}

/// 加锁的一个值（本包里的静态缓存用：dsh 的探测、`ClaudePaths` 的版本号）。
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// semver 版本号（`0.1.5-rc.3`）：按 major.minor.patch 比，再按 semver 的预发布规则比（有预发布 < 没有；
/// 逐段比，纯数字段按数值、数字段 < 字母段、段数多的大）。构建元数据（`+…`）忽略。
public struct DshVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ text: String) {
        let withoutBuild = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, let major = Int(core[0]), let minor = Int(core[1]), let patch = Int(core[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        var prerelease: [String] = []
        if parts.count == 2 {
            prerelease = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !prerelease.contains(where: \.isEmpty) else { return nil }
        }
        self.init(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (lhs: DshVersion, rhs: DshVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
