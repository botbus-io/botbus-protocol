import Foundation

/// 桌面版随包分发的 CLI 与桌面日志版本一致；不要用 npx 缓存里的旧版本打开它的会话。
enum DshDesktopInstallation {
    static var defaultBundles: [URL] {
        #if os(macOS)
        return [URL(fileURLWithPath: "/Applications/DeepSeek Harness.app", isDirectory: true),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DeepSeek Harness.app")]
        #else
        return []
        #endif
    }

    static func detect(bundles: [URL], node: String?, fileManager: FileManager) -> DshInstallation? {
        var best: (installation: DshInstallation, version: DshVersion)?
        for bundle in bundles {
            let contents = bundle.appendingPathComponent("Contents")
            let cli = contents.appendingPathComponent("Resources/runtime/cli/bin/dsh").path
            guard fileManager.isExecutableFile(atPath: cli),
                  let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == "com.deepseek.dsh",
                  let text = info["CFBundleShortVersionString"] as? String, let version = DshVersion(text) else { continue }
            if best.map({ version > $0.version }) ?? true {
                best = (DshInstallation(kind: .binary, executable: cli, leadingArguments: [], version: text, node: node), version)
            }
        }
        return best?.installation
    }
}
