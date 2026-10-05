import Foundation
import BotBusConnectorKit

/// 电脑上删掉、归档的 Claude 会话：连接器定期核对时看的两样东西（都只读）。
///
/// - transcript：`~/.claude/projects/<目录>/<sessionId>.jsonl` 还在不在。Claude 桌面 App 删会话时连 transcript 一起删
///   （它判断安全时），手动删文件、Claude Code 定期清理也是这样。
/// - 桌面 App 的会话记录：`claude-code-sessions/<org>/<account>/local_<uuid>.json`，`cliSessionId` 指向 transcript，
///   `isArchived` 是侧栏的归档。删会话时记录一定删，transcript 别的进程写过（比如手机续聊）就可能留着。
///
/// 读不了一律回 nil：不知道不等于没了，连接器那边这一轮就不摘。
enum ClaudeSessionPresence {
    /// `projects` 下一层目录里所有 transcript 的 session id。`projects` 或其中某个目录读不了返回 nil。
    static func transcriptIDs(in projectsDirectory: URL) -> Set<String>? {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(at: projectsDirectory,
                                                                     includingPropertiesForKeys: [.isDirectoryKey])
        else { return nil }
        var ids: Set<String> = []
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
            for name in files where name.hasSuffix(".jsonl") { ids.insert(String(name.dropLast(6))) }
        }
        return ids
    }
}

/// Claude 桌面 App 侧栏里的会话（按 transcript 的 session id），由 `read` 从记录目录得出。
struct ClaudeDesktopSessionIndex: Equatable, Sendable {
    /// 有记录的会话 → 记录所在的账号目录（`<root>/<org>/<account>`）。
    var recorded: [String: String] = [:]
    /// 侧栏里归档了的会话。
    var archived: Set<String> = []
    /// 这一次读到的账号目录。整个账号目录没了（退出登录、卸载）不算删了里面的会话。
    var accounts: Set<String> = []

    /// 一份记录读出来的样子，按路径、修改时间与大小缓存：记录有几百份、每份带整套 MCP 配置，不必每轮都重新解析。
    struct Record: Equatable, Sendable {
        var stamp: String
        var sessionID: String?
        var isArchived: Bool
    }

    static let recordPrefix = "local_"

    /// 读所有根目录。根目录不存在算没装桌面 App（不是错）；存在却读不了、某份记录解析不了（正在写）都回 nil。
    /// - Parameter cache: 上一次的缓存，返回时换成这一次的（只留还在的记录）。
    static func read(roots: [URL], cache: inout [String: Record]) -> ClaudeDesktopSessionIndex? {
        let fileManager = FileManager.default
        var index = ClaudeDesktopSessionIndex()
        var fresh: [String: Record] = [:]
        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue, let orgs = try? fileManager.contentsOfDirectory(atPath: root.path) else { return nil }
            for org in orgs {
                let orgURL = root.appendingPathComponent(org, isDirectory: true)
                guard isDirectoryEntry(orgURL) else { continue }
                guard let accounts = try? fileManager.contentsOfDirectory(atPath: orgURL.path) else { return nil }
                for account in accounts {
                    let accountURL = orgURL.appendingPathComponent(account, isDirectory: true)
                    guard isDirectoryEntry(accountURL) else { continue }
                    guard let names = try? fileManager.contentsOfDirectory(atPath: accountURL.path) else { return nil }
                    let accountKey = accountURL.path
                    index.accounts.insert(accountKey)
                    for name in names where name.hasPrefix(recordPrefix) && name.hasSuffix(".json") {
                        let url = accountURL.appendingPathComponent(name)
                        guard let record = record(at: url, cached: cache[url.path]) else { return nil }
                        fresh[url.path] = record
                        guard let sessionID = record.sessionID else { continue }
                        index.recorded[sessionID] = accountKey
                        if record.isArchived { index.archived.insert(sessionID) }
                    }
                }
            }
        }
        cache = fresh
        return index
    }

    private static func isDirectoryEntry(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// 一份记录。没有 `cliSessionId` 的（刚建、CLI 还没吐 init）照常算一份，只是不对应任何会话；读不出、不是 JSON 回 nil。
    private static func record(at url: URL, cached: Record?) -> Record? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        let stamp = "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? -1)"
        if let cached, cached.stamp == stamp { return cached }
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let sessionID = (object["cliSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Record(stamp: stamp, sessionID: sessionID, isArchived: object["isArchived"] as? Bool ?? false)
    }
}
