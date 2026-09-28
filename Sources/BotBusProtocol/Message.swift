import Foundation

/// 消息里的一张图（协议 2.9）。字节在 Relay 的产物存储里，这里只是引用。
/// 手机发图时 `StartTask` / `FollowUp.attachments` 也用这个类型。
public struct MessageAttachment: Codable, Hashable, Sendable {
    public var artifactId: String
    public var contentType: String
    /// 上传后的字节数。
    public var size: Int
    /// 像素宽高，给客户端先按比例占位。
    public var width: Int?
    public var height: Int?

    public init(artifactId: String, contentType: String, size: Int, width: Int? = nil, height: Int? = nil) {
        self.artifactId = artifactId
        self.contentType = contentType
        self.size = size
        self.width = width
        self.height = height
    }
}

/// Agent 回复里提到的一个本机文件（协议 2.9）。手机点了才由 Mac 上传（`fetchFile`）。
public struct MessageFileRef: Codable, Hashable, Sendable {
    /// Mac 上的绝对路径，`fetchFile` 原样带回。
    public var path: String
    public var name: String
    public var contentType: String
    /// 原文件字节数。
    public var size: Int
    /// 已上传时才有。
    public var artifactId: String?

    public init(path: String, name: String, contentType: String, size: Int, artifactId: String? = nil) {
        self.path = path
        self.name = name
        self.contentType = contentType
        self.size = size
        self.artifactId = artifactId
    }
}

/// 一条对话记录。
///
/// **只随 `fetchMessages` 按需下发，不进常规快照**——快照是每次变化都全量重发的，
/// 把几十条消息塞进去等于给手表的每一次长轮询都加上几十 KB。
///
/// 协议 2.9 起 `text` 可以是空串——只带图片附件、不带文字的用户消息就是这样。
/// 图还在 Mac 上排队上传时，这种消息会先不带 `attachments` 发一次，补发时才带上。
public struct Message: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        case user
        case agent
        /// 工具调用的一行摘要：执行了什么命令、改了哪个文件。
        case tool
    }

    /// 同一条消息重复拉取时必须稳定，客户端据此去重与做 diff。
    public var id: String
    public var role: Role
    public var text: String
    public var createdAt: String
    /// 消息里的图（协议 2.9）：用户发的图，或 Agent 生成的图（如 Codex imageGeneration）。
    public var attachments: [MessageAttachment]?
    /// Agent 回复里提到的本机文件（协议 2.9）。
    public var files: [MessageFileRef]?

    public init(id: String, role: Role, text: String, createdAt: String,
                attachments: [MessageAttachment]? = nil, files: [MessageFileRef]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
        self.files = files
    }
}

/// 一次 `fetchMessages` 的结果。
///
/// `agentId` 由 Relay 按发来这一帧的连接盖章，负载里冒充别人不生效。
/// `hasMore` 表示更早的消息被截掉了，界面上应当说一句"只显示最近 N 条"。
public struct TaskMessages: Codable, Hashable, Sendable {
    /// 协议里的完整任务 id（`codex:<threadId>` / `claude:<sessionId>`）。
    public var taskId: String
    public var agentId: String
    public var messages: [Message]
    public var hasMore: Bool
    public var fetchedAt: String

    public init(taskId: String, agentId: String, messages: [Message], hasMore: Bool, fetchedAt: String) {
        self.taskId = taskId
        self.agentId = agentId
        self.messages = messages
        self.hasMore = hasMore
        self.fetchedAt = fetchedAt
    }

    /// 协议规定的上限，三端共用。
    ///
    /// `maxMessages` 只数用户与 Agent 的消息（`role != .tool`）：一次拉取给最近这么多条对话，
    /// 夹在它们之间的工具行另算，最多 `maxToolMessages` 条（多了丢最旧的），所以 `messages` 总长不超过 `maxEntries`。
    public static let maxMessages = 40
    public static let maxToolMessages = 160
    public static let maxEntries = maxMessages + maxToolMessages
    /// 单条消息最多带几张图（协议 2.9）。
    public static let maxAttachmentsPerMessage = 4
}
