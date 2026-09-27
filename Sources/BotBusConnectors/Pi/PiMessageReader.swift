import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 从 `~/.pi/agent/sessions/*/<时间戳>_<sessionId>.jsonl` 读对话记录。
///
/// 只取**当前分支**（最后一条沿 `parentId` 回溯）：`/tree` 分叉后被丢下的那一支不是这个会话的现状，
/// 混进来会让一问两答看起来像模型自相矛盾。映射：
/// - user 文本与图片 → `.user`（纯图片的也算一条）；assistant 文本 → `.agent`（thinking 不进，同 Codex 的 reasoning）；
/// - assistant 的每个 toolCall → 一行 `.tool` 摘要；toolResult 跳过（正文往往是整个文件）；
/// - bashExecution（用户在 pi 里敲的 `!命令`）→ `.tool` 的 `$ 命令`。
///
/// id 用 entry 的 id，同一条 entry 里的工具调用加 `#n`，重复拉取时保持稳定。
public struct PiMessageReader: MessageReader {
    public var kind: ConnectorKind { .pi }

    private let paths: @Sendable () -> PiPaths

    public init(paths: @escaping @Sendable () -> PiPaths = { PiPaths() }) {
        self.paths = paths
    }

    public func entries(taskId: String, limit: Int) async throws -> (entries: [TranscriptEntry], hasMore: Bool) {
        let sessionID = try nativeTaskId(taskId, kind: .pi)
        guard let url = PiSessionReader(paths: paths()).sessionFile(for: sessionID) else {
            throw ConnectorError("没找到这个 Pi 会话的记录文件")
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ConnectorError("读不到会话记录文件")
        }
        guard let file = PiSessionFile.parse(data) else {
            throw ConnectorError("Pi 会话记录的格式认不出来")
        }
        // 路径候选只给窗口里的回复认：先不认路径整理全部，截完再按 id 找回那几条回复的原文。
        let branch = file.branch
        let all = Self.entries(in: branch, fallback: file.header.timestamp)
        let (window, hasMore) = TranscriptWindow.latest(all, limit: limit)
        let wanted = Set(window.filter { $0.message.role == .agent }.map(\.message.id))
        var rawReplies: [String: String] = [:]
        for (ordinal, entry) in branch.enumerated() {
            guard case .message(let message) = entry.kind, message.role == .assistant else { continue }
            let id = Self.messageId(entry, ordinal: ordinal)
            if wanted.contains(id) { rawReplies[id] = message.text }
        }
        return (addingPathCandidates(to: window) { rawReplies[$0.message.id] }, hasMore)
    }

    /// entry 没有 id（更早的线性格式）时退回行序；树格式下 id 必在。
    private static func messageId(_ entry: PiSessionFile.Entry, ordinal: Int) -> String {
        entry.id ?? "entry-\(ordinal)"
    }

    /// 当前分支上的全部消息，升序，**不带路径候选**（由调用方只给窗口补）。
    /// `branch` 是 `PiSessionFile.branch`：算一次要建一张 id 表，调用方算好传进来。
    private static func entries(in branch: [PiSessionFile.Entry], fallback headerTimestamp: Date?) -> [TranscriptEntry] {
        let fallback = headerTimestamp ?? Date(timeIntervalSince1970: 0)
        var result: [TranscriptEntry] = []
        for (ordinal, entry) in branch.enumerated() {
            guard case .message(let message) = entry.kind else { continue }
            let id = messageId(entry, ordinal: ordinal)
            let createdAt = ProtocolJSON.timestamp(message.timestamp ?? entry.timestamp ?? fallback)
            func append(_ id: String, _ role: Message.Role, _ raw: String, images: [ImageSource] = []) {
                // 截断与判空交给 `transcriptEntry`：只有空白的正文不出气泡，但带图的照留。
                if let entry = transcriptEntry(id: id, role: role, text: raw, images: images, createdAt: createdAt,
                                               extractPaths: false) {
                    result.append(entry)
                }
            }
            switch message.role {
            case .user:
                let images = message.imageBlocks.compactMap { ImageSource(base64: $0.data, contentType: $0.mimeType) }
                append(id, .user, message.text, images: images)
            case .assistant:
                append(id, .agent, message.text)
                for (index, summary) in message.toolCalls.enumerated() {
                    append("\(id)#\(index + 1)", .tool, summary)
                }
            case .bashExecution:
                if let command = message.command { append(id, .tool, "$ \(PiText.singleLine(command))") }
            case .toolResult, .other:
                continue
            }
        }
        return result
    }
}
