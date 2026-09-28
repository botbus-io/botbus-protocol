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
/// `worktree` 非 nil（协议 3.4，BotBus 开的 worktree 会话）时范围从基准分支的 merge-base 算起，清单带 `mergeTarget`。
public protocol WorkingChangesUploading: Sendable {
    func upload(directory: String, worktree: ManagedWorktree?) async throws -> String?
}

/// BotBus 从手机开的一个 worktree（协议 3.4）。Agent 本机持久化，只有有记录的才能合并。
public struct ManagedWorktree: Codable, Hashable, Sendable {
    /// worktree 根目录（真实路径），`<仓库>/.claude/worktrees/<名字>`。
    public var path: String
    /// 主仓库根目录（真实路径）。
    public var repository: String
    /// worktree 自己的分支，`botbus/<名字>`。
    public var branch: String
    /// 建它时 `projectPath` 所在那份检出（通常是主仓库）的当前分支：合并落到这里。
    public var baseBranch: String
    /// 建它时基准分支的提交。基准分支之后被删掉时，差异面板拿它当比较起点。
    public var baseCommit: String

    public init(path: String, repository: String, branch: String, baseBranch: String, baseCommit: String) {
        self.path = path
        self.repository = repository
        self.branch = branch
        self.baseBranch = baseBranch
        self.baseCommit = baseCommit
    }

    /// `directory` 是不是在这个 worktree 里（根目录本身或它的子目录）。只比字符串前缀、不读盘：
    /// `path` 是真实路径（解开了软链接，`/private/var/…` 而不是 `/var/…`），调用方也得传真实路径。
    /// 任务盖过章的工作目录可以直接传（连接器报的 cwd 与 BotBus 交给连接器的 worktree 目录都是真实路径）；
    /// 来路不明的目录先 `TranscriptFileRefs.realPath`，`WorktreeManager.worktree(containing:)` 就是这么做的。
    public func contains(_ directory: String) -> Bool {
        directory == path || directory.hasPrefix(path + "/")
    }
}

/// `WorktreeManaging.create` 建好的结果。
public struct WorktreeCreation: Sendable, Equatable {
    /// 交给连接器的 cwd：worktree 里与原 `projectPath` 对应的目录。
    public var workingDirectory: String
    public var worktree: ManagedWorktree

    public init(workingDirectory: String, worktree: ManagedWorktree) {
        self.workingDirectory = workingDirectory
        self.worktree = worktree
    }
}

/// `WorktreeManaging.mergeAndRemove` 成功时的两种结果。
public enum WorktreeMergeOutcome: Sendable, Equatable {
    /// 合并了（或本来就没什么可合），worktree、分支与记录都删了。
    case merged
    /// squash 提交已经在基准分支上，但 worktree 里又有了新文件（合并期间才写进去的），所以 worktree、它的分支与
    /// 记录都留着没删。调用方应当告诉手机、不隐藏会话：再合并一次会把新文件也合进去。
    case mergedButKept
}

/// 手机开的 worktree 会话（协议 3.4）：建、查、合并回检出分支。git 写操作在 AgentCore 的 `WorktreeManager`。
public protocol WorktreeManaging: Sendable {
    /// 在 `projectPath` 所在仓库新开一个 worktree。建不了（不是 git 仓库、没有提交、detached HEAD）返回 nil，
    /// 调用方照旧在 `projectPath` 里跑；真出错（git 失败、磁盘满）抛错。
    func create(from projectPath: String) async throws -> WorktreeCreation?
    /// 连接器没起来：删掉刚建的 worktree、分支与记录。尽力而为，不抛。
    func discard(_ worktree: ManagedWorktree) async
    /// 有记录、目录还在、`directory` 在它里面的那个 worktree。
    func worktree(containing directory: String) async -> ManagedWorktree?
    /// squash 合并回 `baseBranch`，成功后删 worktree、分支与记录。失败抛错（文案给手机看），什么都不删。
    /// 合并落地但 worktree 删不掉（又有了新文件）时返回 `.mergedButKept`，见 `WorktreeMergeOutcome`。
    func mergeAndRemove(_ worktree: ManagedWorktree, message: String) async throws -> WorktreeMergeOutcome
}

/// 远程操作（协议 2.12）：开关这台电脑的桌面远程操作，返回预览产物。
public protocol RemoteControlling: Sendable {
    func startSession() async throws -> Artifact
    func stopSession() async
}
