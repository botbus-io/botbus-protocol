import Foundation
import BotBusProtocol

/// `CommandDispatcher` 用到的几项本机服务，都要经 Relay 上传下载，所以实现留在私有的 AgentCore；
/// Kit 只定义它们对分发器露出的那一小截，测试里用假实现即可。

/// `MessageAttachmentResolving.resolve` 的结果：与 entries 一一对应的消息，以及每条是否还有图在排队（或正在传）。
public struct ResolvedAttachments: Sendable {
    public var messages: [Message]
    /// 下标与 `messages` 相同。true = 这条还有图没传好，补发时可能带上。
    public var pending: [Bool]
    /// 有任何一条在等图：调用方应在 `drainPending()` 后再发一次。
    public var hasPending: Bool { pending.contains(true) }

    public init(messages: [Message], pending: [Bool]) {
        self.messages = messages
        self.pending = pending
    }
}

/// 对话里图片的上传与去重（协议 2.9）。
public protocol MessageAttachmentResolving: Sendable {
    /// 把能立刻填的附件填进消息；`hasPending` 为 true 时，调用方应在 `drainPending()` 后再发一次。
    func resolve(_ entries: [TranscriptEntry], agentId: String) async -> ResolvedAttachments
    /// 把排队的图传完。
    func drainPending() async
}

/// 手机随 `startTask` / `followUp` 发来的图（协议 2.9）：调用连接器之前先下载到本机。
public protocol AttachmentReceiving: Sendable {
    func receive(commandId: String, attachments: [MessageAttachment], agentId: String) async throws -> [URL]
}

/// 手机按需取回 Agent 回复里提到的文件（协议 2.9 的 `fetchFile`），也给文件卡片填 artifactId。
public protocol FileFetching: Sendable {
    /// 上传这个文件，返回产物 id。
    func fetch(url: URL) async throws -> String
    /// 已上传且未过期的产物 id，没有就 nil。
    func artifactId(for url: URL) async -> String?
}

/// 手机看任务目录里没提交的改动（协议 2.11 的 `fetchChanges`）：读 git 并上传，返回产物 id。
public protocol WorkingChangesUploading: Sendable {
    func upload(directory: String) async throws -> String?
}

/// 远程操作（协议 2.12）：开关这台电脑的桌面远程操作，返回预览产物。
public protocol RemoteControlling: Sendable {
    func startSession() async throws -> Artifact
    func stopSession() async
}
