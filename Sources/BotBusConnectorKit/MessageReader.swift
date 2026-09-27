import Foundation
import os
import BotBusProtocol

/// 读一个任务的对话记录。
///
/// **故意不挂在 `TaskConnector` 上。** 连接器是"能执行命令的后端"，而看聊天记录必须在
/// 连接器没跑的时候也能用：Codex 即使 app-server 没起来，SQLite 也照样读得到；
/// Claude 即使没装 hooks，transcript 文件也在那儿。把它绑进连接器等于让"能不能看"
/// 取决于"能不能发命令"，那是两件事。
public protocol MessageReader: Sendable {
    var kind: ConnectorKind { get }

    /// 最近 `limit` 条**对话**（用户与 Agent 的消息），加上夹在其间的工具行，**按时间升序**
    /// （最旧的在前，方便界面从上往下渲染）。取窗口的规则统一走 `TranscriptWindow.latest`。
    /// `hasMore` 表示更早的对话被截掉了。
    ///
    /// 产出的是 `TranscriptEntry` 而不是 `Message`：图片只报来源（文件路径或内嵌字节），
    /// 读字节、压缩、上传都在读取器之外做，读取器保持"只读、只解析"。
    func entries(taskId: String, limit: Int) async throws -> (entries: [TranscriptEntry], hasMore: Bool)
}

public extension MessageReader {
    /// 只要文字的调用方用这个；图片来源直接丢掉，`Message.attachments` 也不会有。
    public func messages(taskId: String, limit: Int) async throws -> (messages: [Message], hasMore: Bool) {
        let (entries, hasMore) = try await entries(taskId: taskId, limit: limit)
        return (entries.map(\.message), hasMore)
    }
}

/// 把原生 id 从协议 id（`codex:<threadId>`）里剥出来。
public func nativeTaskId(_ taskId: String, kind: ConnectorKind) throws -> String {
    let prefix = "\(kind.rawValue):"
    guard taskId.hasPrefix(prefix) else { throw ConnectorError("任务 id 不属于 \(kind.rawValue)：\(taskId)") }
    let native = String(taskId.dropFirst(prefix.count))
    guard !native.isEmpty else { throw ConnectorError("任务 id 不合法：\(taskId)") }
    return native
}

public func truncateMessage(_ text: String, limit: Int = TaskMessages.maxMessageLength) -> String {
    let trimmed = text.trimmed
    return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
}

/// 一次拉取的窗口：最近 `limit` 条对话（`role != .tool`），外加夹在它们之间、以及最旧那条之前紧挨着的工具行
/// ——那几行属于最旧那条回复所在的一轮。
///
/// 工具行不占对话名额：一轮里 Agent 常常连调几十次工具，按总条数截，40 条里剩不下几句人话。
/// 工具行另有 `TaskMessages.maxToolMessages` 的上限，超了丢**最旧**的：最近在干什么最值得看。
public enum TranscriptWindow {
    /// `ascending`：按时间升序的全部（或足够多的）条目。
    public static func latest(_ ascending: [TranscriptEntry], limit: Int) -> (entries: [TranscriptEntry], hasMore: Bool) {
        let limit = min(max(limit, 1), TaskMessages.maxMessages)
        var start = ascending.startIndex
        var conversation = 0
        var hasMore = false
        for index in ascending.indices.reversed() where ascending[index].message.role != .tool {
            if conversation == limit {
                start = index + 1
                hasMore = true
                break
            }
            conversation += 1
        }
        let window = ascending[start...]
        var excess = window.lazy.filter { $0.message.role == .tool }.count - TaskMessages.maxToolMessages
        guard excess > 0 else { return (Array(window), hasMore) }
        let trimmed = window.filter { entry in
            guard entry.message.role == .tool, excess > 0 else { return true }
            excess -= 1
            return false
        }
        return (trimmed, hasMore)
    }

    /// 倒着翻页的读取器（SQL）用：手上已有的条目（新的在前）够不够凑出窗口——对话条数超过 `limit` 才算够。
    public static func isEnough(_ newestFirst: [TranscriptEntry], limit: Int) -> Bool {
        newestFirst.lazy.filter { $0.message.role != .tool }.count > min(max(limit, 1), TaskMessages.maxMessages)
    }
}

/// 工具行的正文上限：它只是一行摘要（长命令、长参数），一次拉取最多一百多行，按对话的 1000 字给太占体积。
public let maxToolTextLength = 200

/// 五家读取器共用的收尾：截断正文（工具行按 `maxToolTextLength`），再判空，组成一条 entry。
///
/// 判空必须在截断（顺带 trim）之后，不然只有空白的正文会变成空气泡；
/// 但有图就要留——2.9 起纯图片消息（`text == ""`）也是一条对话。
///
/// Agent 回复里的文件路径（`pathCandidates`）从**截断前**的原文里认：长回复末尾的"已保存到 `out/a.png`"
/// 不能因为正文只给手机看前 1000 字就丢了。只认 `.agent`：用户消息里的路径不是 Agent 产出的，
/// 工具行只有文件名摘要。放在这里是为了五家读取器一处生效，不用各自记得调用。
///
/// `extractPaths: false` 给"整份解析再截尾"的读取器（Claude、Pi）用：先不认路径，截出窗口后只给窗口里的回复补
/// ——几千条的会话不必每次拉取都把每条回复过一遍正则。其余读取器在 SQL / Gateway 那一步就只取了窗口。
public func transcriptEntry(id: String, role: Message.Role, text raw: String?, images: [ImageSource] = [],
                     createdAt: String, extractPaths: Bool = true) -> TranscriptEntry? {
    let text = truncateMessage(raw ?? "", limit: role == .tool ? maxToolTextLength : TaskMessages.maxMessageLength)
    guard !text.isEmpty || !images.isEmpty else { return nil }
    let paths = role == .agent && extractPaths ? TranscriptFileRefs.candidates(in: raw ?? "") : []
    return TranscriptEntry(message: Message(id: id, role: role, text: text, createdAt: createdAt), images: images,
                           pathCandidates: paths)
}

/// 给窗口里的 Agent 回复补路径候选。`rawText` 取这条回复截断前的原文（读取器从自己手上的原始数据里找，
/// 不必为此给每条 entry 留一份全文）。
public func addingPathCandidates(to window: [TranscriptEntry], rawText: (TranscriptEntry) -> String?) -> [TranscriptEntry] {
    window.map { entry in
        guard entry.message.role == .agent, let raw = rawText(entry) else { return entry }
        var filled = entry
        filled.pathCandidates = TranscriptFileRefs.candidates(in: raw)
        return filled
    }
}
