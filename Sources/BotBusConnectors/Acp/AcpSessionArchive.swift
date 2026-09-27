import Foundation
import os
import BotBusProtocol
import BotBusConnectorKit

/// BotBus 自己拉起的 ACP 会话记在本机（spec「电脑上已有的会话」）：很多 agent 没有 `session/list`，
/// 不记的话 app 一重启，手机上发起的任务就全不见了。**不存对话内容**：只留会话 id、目录、标题、时间与状态，
/// `lastMessage`、挂起的审批、系统授权提示、产物一律去掉——重启后这些任务没有"最后一条消息"。
/// 标题是第一条提示词的前 80 个字（`SessionFormatting.titleLimit`），这是文件里唯一来自对话的内容。
///
/// 和 `session/list` 一样只留最近窗口（`SessionFormatting.recentWindow`，7 天）里更新过的：读进来时、每次存盘前都剪一遍。
public actor AcpSessionArchive {
    public static let maxPerConnector = 200
    public static var defaultURL: URL {
        LocalHookServer.defaultSupportDirectory.appendingPathComponent("acp-sessions.json")
    }
    private static let log = Logger(subsystem: "io.botbus.agent", category: "acp")

    private let url: URL?
    private let now: @Sendable () -> Date
    private var byConnector: [String: [TaskRecord]]

    /// - Parameter url: nil = 只在内存里（测试默认）。
    public init(url: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? ProtocolJSON.decoder().decode([String: [TaskRecord]].self, from: data) {
            // 读进来也剥一遍：这是本机明文文件，不假定里面只有元数据。
            byConnector = Self.pruned(decoded.mapValues { $0.map(Self.stripped) }, now: now())
        } else {
            byConnector = [:]
        }
    }

    public func records(connectorId: String) -> [TaskRecord] { byConnector[connectorId] ?? [] }

    public func remember(connectorId: String, record: TaskRecord) {
        let copy = Self.stripped(record)
        var list = (byConnector[connectorId] ?? []).filter { $0.id != copy.id }
        list.append(copy)
        list.sort { $0.updatedAt > $1.updatedAt }
        byConnector[connectorId] = Array(list.prefix(Self.maxPerConnector))
        byConnector = Self.pruned(byConnector, now: now())
        save()
    }

    /// 去掉最近窗口之外的记录（时间解析不了的留着，交给显示那一侧）；剪空的 agent 整个拿掉。
    static func pruned(_ records: [String: [TaskRecord]], now: Date) -> [String: [TaskRecord]] {
        records.compactMapValues { list in
            let kept = list.filter { record in
                guard let updated = AcpConnector.date(record.updatedAt) else { return true }
                return now.timeIntervalSince(updated) <= SessionFormatting.recentWindow
            }
            return kept.isEmpty ? nil : kept
        }
    }

    /// 只留元数据，去掉一切对话内容。
    static func stripped(_ record: TaskRecord) -> TaskRecord {
        var copy = record
        copy.lastMessage = nil
        copy.pendingRequest = nil
        copy.systemPermission = nil
        copy.artifacts = nil
        return copy
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ProtocolJSON.encoder().encode(byConnector).write(to: url, options: .atomic)
        } catch {
            Self.log.error("acp archive save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
