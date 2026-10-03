import Foundation
import BotBusConnectorKit

/// 定位 ~/.codex 下的数据库与 codex 可执行文件。
public struct CodexPaths: Sendable {
    public var codexHome: URL

    public init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.codexHome = codexHome
    }

    /// Codex 的库文件名带 schema 版本号（state_5.sqlite、thread_history_1.sqlite），取号最大的那个。
    public func latestDatabase(prefix: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: codexHome.path)) ?? []
        let candidates = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(prefix + "_"), name.hasSuffix(".sqlite") else { return nil }
            let middle = name.dropFirst(prefix.count + 1).dropLast(".sqlite".count)
            guard let version = Int(middle) else { return nil }
            return (version, name)
        }
        return candidates.max { $0.0 < $1.0 }.map { codexHome.appendingPathComponent($0.1) }
    }

    public var stateDatabase: URL? { latestDatabase(prefix: "state") }
    public var historyDatabase: URL? { latestDatabase(prefix: "thread_history") }

    /// ChatGPT.app 0.158 起将 CLI 移到 `Resources/codex-cli/bin/codex`；旧版仍用
    /// `Resources/codex`。Codex.app 也可能使用新布局，因此两个 bundle 都检查两种路径。
    public static let knownBinaries = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    ]

    /// 在指定的桌面 app 副本中查找 CLI。桥接重启必须用正在运行的那份 app，
    /// 因为系统里可能存在多个同 bundle ID 的副本。
    public static func detectCodexBinary(in appBundleURL: URL,
                                         fileManager: FileManager = .default) -> String? {
        let resources = appBundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let candidates = [
            resources.appendingPathComponent("codex-cli/bin/codex"),
            resources.appendingPathComponent("codex"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }?.path
    }

    public static func detectCodexBinary(fileManager: FileManager = .default) -> String? {
        #if os(Windows)
        return detectWindowsCodexBinary(fileManager: fileManager)
        #else
        // 桌面 app 自带的那份优先（与桌面端同版本、同登录）；没有桌面 app 时（Linux 一直如此）找 npm / Homebrew 装的。
        return knownBinaries.first { fileManager.isExecutableFile(atPath: $0) }
            ?? detectInstalledCLI(locate: { AgentBinary.detect($0, fileManager: fileManager) }, fileManager: fileManager)
        #endif
    }

    #if !os(Windows)
    /// 常见全局目录、nvm 与 PATH 里的 `codex`。npm 全局装的是 `bin/codex.js`（node 脚本），它只是去起
    /// 按平台装进来的原生程序：找得到那个原生程序就直接用它（不依赖 GUI 进程的 PATH 里有 node，结束进程也干净），
    /// 找不到才用脚本本身（`CodexSubprocessLauncher` 会把它旁边的 node 放到 PATH 最前）。Homebrew 装的就是原生程序。
    static func detectInstalledCLI(locate: (String) -> String?, fileManager: FileManager = .default) -> String? {
        guard let binary = locate("codex") else { return nil }
        let resolved = (binary as NSString).resolvingSymlinksInPath
        guard resolved.hasSuffix(npmScriptSuffix) else { return binary }
        let package = String(resolved.dropLast(npmScriptSuffix.count - "/@openai/codex".count))
        return npmNativeBinary(packageDirectory: package, fileManager: fileManager) ?? binary
    }

    static let npmScriptSuffix = "/@openai/codex/bin/codex.js"

    /// `@openai/codex` 包里的原生程序：平台包（`@openai/codex-darwin-arm64` 等，optionalDependencies）装在包自己的
    /// `node_modules` 下，或被提升成它的兄弟目录；更早的版本直接放在包里的 `vendor/`。
    static func npmNativeBinary(packageDirectory: String, fileManager: FileManager = .default) -> String? {
        let scope = (packageDirectory as NSString).deletingLastPathComponent
        for (platform, triple) in nativePlatforms {
            let inside = "vendor/\(triple)/codex/codex"
            let candidates = [
                "\(packageDirectory)/node_modules/@openai/codex-\(platform)/\(inside)",
                "\(scope)/codex-\(platform)/\(inside)",
                "\(packageDirectory)/\(inside)",
            ]
            if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) { return found }
        }
        return nil
    }

    /// 本机能跑的平台包名与 Rust target triple，优先原生架构（Apple 芯片上 x64 的那份也能经 Rosetta 跑）。
    static var nativePlatforms: [(String, String)] {
        #if os(macOS)
        #if arch(arm64)
        return [("darwin-arm64", "aarch64-apple-darwin"), ("darwin-x64", "x86_64-apple-darwin")]
        #else
        return [("darwin-x64", "x86_64-apple-darwin")]
        #endif
        #else
        #if arch(arm64)
        return [("linux-arm64", "aarch64-unknown-linux-musl")]
        #else
        return [("linux-x64", "x86_64-unknown-linux-musl")]
        #endif
        #endif
    }
    #endif

    #if os(Windows)
    /// Windows 上的 Codex CLI 多半是 npm 全局装的（`@openai/codex`）：`codex.cmd` → node → 包里自带的 `codex.exe`。
    /// 能找到包里的原生 `codex.exe` 就直接用它（少两层进程，结束进程树也干净），否则退回 `codex.cmd` / winget / PATH，
    /// 都没有再用 Codex 桌面 app（Microsoft Store 包 `OpenAI.Codex`）解出来的那份。
    static func detectWindowsCodexBinary(fileManager: FileManager) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appData = environment["APPDATA"] ?? home + "\\AppData\\Roaming"
        let localAppData = environment["LOCALAPPDATA"] ?? home + "\\AppData\\Local"
        let vendor = appData + "\\npm\\node_modules\\@openai\\codex\\vendor"
        #if arch(arm64)
        let triples = ["aarch64-pc-windows-msvc", "x86_64-pc-windows-msvc"]
        #else
        let triples = ["x86_64-pc-windows-msvc"]
        #endif
        for triple in triples {
            let candidate = vendor + "\\" + triple + "\\codex\\codex.exe"
            if PlatformPath.isExecutableFile(candidate, fileManager: fileManager) { return candidate }
        }
        if let binary = AgentBinary.detect("codex", fileManager: fileManager) { return binary }
        return newestBinary(inSubdirectoriesOf: localAppData + "\\OpenAI\\Codex\\bin", executable: "codex.exe",
                            fileManager: fileManager)
    }
    #endif

    /// Codex 桌面 app 把 CLI 解到 `%LOCALAPPDATA%\OpenAI\Codex\bin\<哈希>\codex.exe`，目录名是哈希不是版本号，
    /// 更新后旧目录可能还留着（别的哈希目录里也可能只有 `rg.exe`），所以挑修改时间最新、带 `executable` 的那个。
    /// 它与桌面 app 共用 `~/.codex`，登录态也是同一份。
    static func newestBinary(inSubdirectoriesOf root: String, executable: String,
                             fileManager: FileManager = .default) -> String? {
        let candidates = ((try? fileManager.contentsOfDirectory(atPath: root)) ?? []).compactMap { name -> (path: String, modified: Date)? in
            let candidate = ((root as NSString).appendingPathComponent(name) as NSString).appendingPathComponent(executable)
            guard PlatformPath.isExecutableFile(candidate, fileManager: fileManager) else { return nil }
            let modified = (try? fileManager.attributesOfItem(atPath: candidate)[.modificationDate] as? Date) ?? .distantPast
            return (candidate, modified)
        }
        return candidates.max { ($0.modified, $0.path) < ($1.modified, $1.path) }?.path
    }
}
