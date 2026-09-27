import Foundation
import os
import BotBusProtocol

/// `~/Library/Application Support/BotBus/phone-tasks.json` 的读写：手机发起过的任务 id → 第一次见到的时间。
///
/// 只给 Mac 菜单的「手机发起的会话」用，不进协议。`TaskRecord.origin` 只活在连接器内存里，
/// 重启后观察者读回来一律是 `.desktop`；连接器又拿 origin 判断"电脑上正开着、不是我们的进程"，
/// 所以不能反过来改写 origin，另记一份。
///
/// 读取整段容错：文件不在、JSON 坏了都只是列表变短，绝不让 Agent 起不来。
public enum PhoneTaskArchive {
    public static let currentVersion = 1
    private static let log = Logger(subsystem: "io.botbus.agent", category: "phone-tasks")

    private struct File: Codable {
        var version: Int
        var tasks: [Entry]
    }

    private struct Entry: Codable {
        var taskId: String
        var firstSeenAt: String
    }

    public static func load(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let file = try ProtocolJSON.decoder().decode(File.self, from: data)
            var result: [String: String] = [:]
            for entry in file.tasks where !entry.taskId.isEmpty { result[entry.taskId] = entry.firstSeenAt }
            return result
        } catch {
            log.error("phone-tasks.json 解析失败，忽略：\(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    /// 原子写入。写不了只记一条日志：内存里的记录照样有效，下次改动还会再试。
    public static func save(_ tasks: [String: String], to url: URL) {
        let entries = tasks.sorted { $0.key < $1.key }.map { Entry(taskId: $0.key, firstSeenAt: $0.value) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try ProtocolJSON.encoder().encode(File(version: currentVersion, tasks: entries))
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("写 phone-tasks.json 失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 超过上限时丢掉最早见到的（时间相同按 id 定序，保证结果确定）。
    public static func trimmed(_ tasks: [String: String], limit: Int) -> [String: String] {
        guard tasks.count > limit else { return tasks }
        let dropped = tasks.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
            .prefix(tasks.count - limit).map(\.key)
        var kept = tasks
        for id in dropped { kept.removeValue(forKey: id) }
        return kept
    }
}
