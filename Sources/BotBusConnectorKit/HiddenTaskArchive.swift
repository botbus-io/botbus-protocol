import Foundation
import os
import BotBusProtocol

/// `~/Library/Application Support/BotBus/hidden-tasks.json` 的读写：手机「合并并结束」后隐藏的会话（协议 3.4），
/// 任务 id → 隐藏的时间。只读观察器还会读到它们（Claude 的 transcript 留在磁盘上），靠这份记录挡在快照外面。
/// 只在本机，不进协议。
///
/// 读取整段容错：文件不在、JSON 坏了都只是隐藏的会话重新出现，绝不让 Agent 起不来。
public enum HiddenTaskArchive {
    public static let currentVersion = 1
    /// 最多记多少条，超了丢最早隐藏的：很久以前的会话早已沉到观察器的列表底下。
    public static let limit = 2000
    private static let log = Logger(subsystem: "io.botbus.agent", category: "hidden-tasks")

    private struct File: Codable {
        var version: Int
        var tasks: [Entry]
    }

    private struct Entry: Codable {
        var taskId: String
        var hiddenAt: String
    }

    public static func load(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let file = try ProtocolJSON.decoder().decode(File.self, from: data)
            var result: [String: String] = [:]
            for entry in file.tasks where !entry.taskId.isEmpty { result[entry.taskId] = entry.hiddenAt }
            return result
        } catch {
            log.error("hidden-tasks.json 解析失败，忽略：\(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    /// 原子写入。写不了只记一条日志：内存里的记录照样有效，下次隐藏还会再试。
    public static func save(_ tasks: [String: String], to url: URL) {
        let entries = tasks.sorted { $0.key < $1.key }.map { Entry(taskId: $0.key, hiddenAt: $0.value) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try ProtocolJSON.encoder().encode(File(version: currentVersion, tasks: entries))
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("写 hidden-tasks.json 失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 超过上限时丢掉最早隐藏的（时间相同按 id 定序，保证结果确定）。
    public static func trimmed(_ tasks: [String: String], limit: Int = HiddenTaskArchive.limit) -> [String: String] {
        guard tasks.count > limit else { return tasks }
        let dropped = tasks.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
            .prefix(tasks.count - limit).map(\.key)
        var kept = tasks
        for id in dropped { kept.removeValue(forKey: id) }
        return kept
    }
}
