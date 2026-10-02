import Foundation

/// 协议 2.5 三个来源（Hermes、Pi、OpenClaw）共用的本机定位：数据目录与可执行文件。
///
/// 和 `ClaudePaths` 一样**不走 `which`**：Agent 是 GUI 进程，拿不到用户 shell 的 PATH，
/// 也读不到用户在 `.zshrc` 里设的 `PI_CODING_AGENT_DIR` / `HERMES_HOME` / `OPENCLAW_STATE_DIR`，
/// 所以只认默认目录，可执行文件按常见安装位置挨个看。
public enum AgentBinary {
    /// 常见的全局安装目录。npm / pnpm / bun / volta / Homebrew / uv / pipx 都会落在其中之一。
    /// nvm 的目录带版本号，单独展开（见 `nvmBinDirectories`）。
    #if os(Windows)
    /// Windows：原生安装器（`~\.local\bin`，Claude Code 的 `claude.exe` 在这）、npm 全局（`%APPDATA%\npm`，`.cmd` 包装）、
    /// winget 的链接目录、scoop、bun、volta、pnpm、Node 官方安装包。Windows 上后台进程是用户会话里起的，
    /// 拿得到用户的 PATH，所以最后再把 PATH 里的目录也试一遍（见 `detect`）。
    public static var commonDirectories: [String] {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appData = environment["APPDATA"] ?? home + "\\AppData\\Roaming"
        let localAppData = environment["LOCALAPPDATA"] ?? home + "\\AppData\\Local"
        let programFiles = environment["ProgramFiles"] ?? "C:\\Program Files"
        return [
            home + "\\.local\\bin",
            appData + "\\npm",
            localAppData + "\\Microsoft\\WinGet\\Links",
            home + "\\scoop\\shims",
            home + "\\.bun\\bin",
            localAppData + "\\Volta\\bin",
            localAppData + "\\pnpm",
            programFiles + "\\nodejs",
        ]
    }

    /// nvm-windows 把当前版本链接到 `NVM_SYMLINK`（默认 `C:\Program Files\nodejs`，已在上面），不再逐个版本展开。
    public static func nvmBinDirectories(fileManager: FileManager = .default) -> [String] {
        ProcessInfo.processInfo.environment["NVM_SYMLINK"].map { [$0] } ?? []
    }

    /// 按候选目录找一个可执行文件（带 `.exe` / `.cmd` 后缀地试）；`extra` 排在最前，PATH 里的目录排在最后。
    public static func detect(_ name: String, extra: [String] = [],
                              fileManager: FileManager = .default) -> String? {
        let path = PlatformPath.searchPath(in: ProcessInfo.processInfo.environment).map(PlatformPath.splitSearchPath) ?? []
        let directories = extra.map { ($0 as NSString).expandingTildeInPath } + commonDirectories
            + nvmBinDirectories(fileManager: fileManager) + path
        return PlatformPath.findExecutable(name, in: directories, fileManager: fileManager)
    }
    #else
    public static let commonDirectories = [
        "~/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.npm-global/bin",
        "~/.bun/bin",
        "~/.volta/bin",
        "~/Library/pnpm",
        "/usr/bin",
    ]

    /// `~/.nvm/versions/node/<版本>/bin`，版本号新的在前。
    public static func nvmBinDirectories(fileManager: FileManager = .default) -> [String] {
        let root = ("~/.nvm/versions/node" as NSString).expandingTildeInPath
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        return versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(root)/\($0)/bin" }
    }

    /// 按候选目录找一个可执行文件；`extra` 是这个 agent 自己特有的位置，排在最前。
    public static func detect(_ name: String, extra: [String] = [],
                              fileManager: FileManager = .default) -> String? {
        let directories = extra + commonDirectories + nvmBinDirectories(fileManager: fileManager)
        return directories
            .map { (($0 as NSString).expandingTildeInPath as NSString).appendingPathComponent(name) }
            .first { fileManager.isExecutableFile(atPath: $0) }
    }
    #endif

    /// 子进程环境：继承本进程，把可执行文件所在目录（以及它软链接指向的目录）放到 PATH 最前，再叠上 `extra`。
    ///
    /// Pi 与 OpenClaw 是 `#!/usr/bin/env node` 脚本：GUI 进程的 PATH 只有 `/usr/bin:/bin:…`，
    /// 找不到 Homebrew 或 nvm 装的 node，进程一起来就退出。npm 全局装的 node 几乎总和这个脚本在同一个 bin 目录里。
    public static func environment(for executable: String, adding extra: [String: String] = [:],
                                   base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let directories = pathDirectories(for: executable)
        #if os(Windows)
        let existing = PlatformPath.splitSearchPath(PlatformPath.searchPath(in: base) ?? "")
        PlatformPath.setSearchPath(PlatformPath.joinSearchPath(directories + existing.filter { !directories.contains($0) }),
                                   in: &environment)
        #else
        let existing = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        environment["PATH"] = (directories + existing.filter { !directories.contains($0) }).joined(separator: ":")
        #endif
        return environment.merging(extra) { _, injected in injected }
    }

    /// 要放到 PATH 最前的目录：可执行文件所在目录，以及它软链接指向的目录（不同才加）。
    public static func pathDirectories(for executable: String) -> [String] {
        var directories = [(executable as NSString).deletingLastPathComponent]
        let resolved = (executable as NSString).resolvingSymlinksInPath
        let resolvedDirectory = (resolved as NSString).deletingLastPathComponent
        if !directories.contains(resolvedDirectory) { directories.append(resolvedDirectory) }
        return directories
    }
}

/// 定位 Pi（`earendil-works/pi`，旧名 `@mariozechner/pi-coding-agent`）的会话目录与 `pi` 可执行文件。
///
/// 会话是 `~/.pi/agent/sessions/--<cwd 里 / 换成 ->--/<时间戳>_<sessionId>.jsonl`；
/// 目录名反解不回路径（路径里本来就可能有 `-`），真实 cwd 以文件首行 header 为准。
public struct PiPaths: Sendable {
    public var agentDirectory: URL

    public init(agentDirectory: URL = PiPaths.defaultAgentDirectory) {
        self.agentDirectory = agentDirectory
    }

    public static var defaultAgentDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    public var sessionsDirectory: URL { agentDirectory.appendingPathComponent("sessions", isDirectory: true) }

    public func hasPiHome(fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: agentDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func detectPiBinary(fileManager: FileManager = .default) -> String? {
        AgentBinary.detect("pi", fileManager: fileManager)
    }
}

/// 定位 Hermes Agent（Nous Research）的 `~/.hermes/state.db` 与 `hermes` 可执行文件。
public struct HermesPaths: Sendable {
    public var hermesHome: URL

    public init(hermesHome: URL = HermesPaths.defaultHermesHome) {
        self.hermesHome = hermesHome
    }

    public static var defaultHermesHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true)
    }

    /// 会话与消息都在这一个 SQLite（WAL）里；没有 JSONL transcript。
    public var stateDatabase: URL? {
        let url = hermesHome.appendingPathComponent("state.db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func hasHermesHome(fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: hermesHome.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func detectHermesBinary(fileManager: FileManager = .default) -> String? {
        AgentBinary.detect("hermes", fileManager: fileManager)
    }
}

/// 定位 OpenClaw 的状态目录（`~/.openclaw`）、配置文件与 `openclaw` 可执行文件。
///
/// OpenClaw 的会话在 Gateway 自己的 SQLite 里（部分 transcript 行是 zstd 压缩的），所以不读文件，
/// 一切经 Gateway WebSocket（默认 `127.0.0.1:18789`）。这里只负责找配置里的端口与 token。
public struct OpenClawPaths: Sendable {
    public var stateDirectory: URL

    public init(stateDirectory: URL = OpenClawPaths.defaultStateDirectory) {
        self.stateDirectory = stateDirectory
    }

    public static var defaultStateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw", isDirectory: true)
    }

    public static let defaultGatewayPort = 18789

    public var configFile: URL { stateDirectory.appendingPathComponent("openclaw.json") }

    public func hasStateDirectory(fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: stateDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func detectOpenClawBinary(fileManager: FileManager = .default) -> String? {
        AgentBinary.detect("openclaw", fileManager: fileManager)
    }
}
