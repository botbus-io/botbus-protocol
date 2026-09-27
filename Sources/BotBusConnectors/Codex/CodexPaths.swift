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
        knownBinaries.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
