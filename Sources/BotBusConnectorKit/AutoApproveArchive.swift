import Foundation
import os
import BotBusProtocol

/// `~/Library/Application Support/BotBus/auto-approve.json` 的读写：开了「自动批准」（协议 3.3）的项目路径。
///
/// 路径是 `TaskStore` 盖章后的 `projectPath`（worktree 里的会话记主仓库），只在这台电脑上有意义。
/// 读取整段容错：文件不在、JSON 坏了都只是当作一个都没开——宁可多问一次，也不能让 Agent 起不来。
public enum AutoApproveArchive {
    public static let currentVersion = 1
    private static let log = Logger(subsystem: "io.botbus.agent", category: "auto-approve")

    private struct File: Codable {
        var version: Int
        var projects: [String]
    }

    public static func load(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let file = try ProtocolJSON.decoder().decode(File.self, from: data)
            return Set(file.projects.filter { !$0.isEmpty })
        } catch {
            log.error("auto-approve.json 解析失败，忽略：\(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// 原子写入。写不了只记一条日志：内存里的设置照样生效，下次改动还会再试。
    public static func save(_ projects: Set<String>, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try ProtocolJSON.encoder().encode(File(version: currentVersion, projects: projects.sorted()))
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("写 auto-approve.json 失败：\(String(describing: error), privacy: .public)")
        }
    }
}
