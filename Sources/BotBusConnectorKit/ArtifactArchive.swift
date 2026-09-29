import Foundation
#if canImport(os)
import os
#endif
import BotBusProtocol

/// 挂在任务上的一件产物，加上预览的来源键（同一任务同一端口/目录重新分享时靠它找到旧的那条替换掉）。
public struct StoredArtifact: Codable, Hashable, Sendable {
    public var artifact: Artifact
    /// 仅 preview 有：`port:<n>` 或 `dir:<绝对路径>`（AgentCore 的 `PreviewOrigin.artifactOriginKey` 算出来）。
    public var origin: String?
}

/// `~/Library/Application Support/BotBus/artifacts.json` 的读写。按任务存，重启后图片、文件、链接仍挂在原任务上。
///
/// 读取整段容错：文件不在、JSON 坏了、某一件产物的形状将来变了，都只是少几条，绝不让 Agent 起不来。
public enum ArtifactArchive {
    public static let currentVersion = 1
    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "artifacts")

    private struct File: Codable {
        var version: Int
        var tasks: [Entry]
    }

    private struct Entry: Codable {
        var taskId: String
        var artifacts: [StoredArtifact]

        init(taskId: String, artifacts: [StoredArtifact]) {
            self.taskId = taskId
            self.artifacts = artifacts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            taskId = try container.decode(String.self, forKey: .taskId)
            // 一件解不出来（例如将来多了一种 kind）只丢这一件。
            artifacts = try container.decode([Lossy<StoredArtifact>].self, forKey: .artifacts).compactMap(\.value)
        }
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// 读出按任务分组的产物。**预览不跨重启**：隧道与托管进程都随 app 退出而结束（`stopAll()`），
    /// 留着它们只会让手机上多一颗点了必然 503 的按钮。其余过期的一并去掉。
    public static func load(from url: URL, now: Date) -> [String: [StoredArtifact]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let file: File
        do {
            file = try ProtocolJSON.decoder().decode(File.self, from: data)
        } catch {
            log.error("artifacts.json 解析失败，忽略：\(String(describing: error), privacy: .public)")
            return [:]
        }
        var result: [String: [StoredArtifact]] = [:]
        for entry in file.tasks where !entry.taskId.isEmpty {
            let kept = entry.artifacts
                .filter { $0.artifact.kind != .preview && !isExpired($0.artifact, now: now) }
                .prefix(TaskRecord.maxArtifacts)
            guard !kept.isEmpty else { continue }
            result[entry.taskId, default: []].append(contentsOf: kept)
        }
        return result
    }

    /// 原子写入。写不了只记一条日志：内存里的状态照样对外有效，下次改动还会再试。
    public static func save(_ artifacts: [String: [StoredArtifact]], to url: URL) {
        let entries = artifacts
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { Entry(taskId: $0.key, artifacts: $0.value) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try ProtocolJSON.encoder().encode(File(version: currentVersion, tasks: entries))
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("写 artifacts.json 失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// `expiresAt` 已经过去。解析不了的时间不算过期——宁可多显示一条，也不凭空删用户的东西。
    public static func isExpired(_ artifact: Artifact, now: Date) -> Bool {
        guard let text = artifact.expiresAt, let date = try? Date(text, strategy: .iso8601) else { return false }
        return date <= now
    }
}
