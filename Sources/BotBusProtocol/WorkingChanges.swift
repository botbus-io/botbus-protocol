import Foundation

/// 任务目录里还没提交的改动（协议 2.11）：`fetchChanges` 的结果。
///
/// **不走 WebSocket 帧**：几百个文件的 diff 能有几 MB。Mac 把它编码成 JSON 作为一份产物上传
/// （`application/json`，与其余产物同一个端点、同一个大小上限），产物 id 随 `CommandResult.artifactId` 返回，
/// 手机再按普通产物去取字节。它不进 `Task.artifacts`。
///
/// 内容就是 `git diff HEAD` 加上未跟踪的文件：已暂存、未暂存、新建的都算，范围限定在任务的工作目录
/// （worktree 会话是 worktree 目录）之内。
public struct WorkingChanges: Codable, Hashable, Sendable {
    /// Mac 上的工作目录（绝对路径），界面只显示最后一段。
    public var directory: String
    /// 当前分支；detached HEAD 时省略。
    public var branch: String?
    public var generatedAt: String
    /// 按路径排序；超过 `maxFiles` 时只列前面这些，`totalFiles` 是实际个数。
    public var files: [ChangedFile]
    public var totalFiles: Int

    public init(directory: String, branch: String? = nil, generatedAt: String, files: [ChangedFile],
                totalFiles: Int? = nil) {
        self.directory = directory
        self.branch = branch
        self.generatedAt = generatedAt
        self.files = files
        self.totalFiles = totalFiles ?? files.count
    }

    /// 最多列多少个文件。
    public static let maxFiles = 300
    /// 单个文件的 diff 最多带多少字节，超了在行边界截断并标 `truncated`。
    public static let maxPatchBytes = 200_000
    /// 所有 diff 加起来最多多少字节；用完之后的文件只列名字与行数，不带 diff，同样标 `truncated`。
    public static let maxTotalPatchBytes = 4_000_000
    /// 产物的内容类型。
    public static let contentType = "application/json"
}

public struct ChangedFile: Codable, Hashable, Sendable, Identifiable {
    /// 同一份清单里路径不重复。
    public var id: String { path }

    public enum Status: String, Codable, Sendable, CaseIterable {
        case modified, added, deleted, renamed, untracked
        /// 合并冲突还没解决。
        case conflicted
    }

    /// 相对 `WorkingChanges.directory` 的路径。
    public var path: String
    /// 改名前的路径（`renamed`）。
    public var oldPath: String?
    public var status: Status
    /// 增删的行数；二进制文件省略。
    public var added: Int?
    public var removed: Int?
    /// 二进制文件：没有 diff。
    public var binary: Bool?
    /// unified diff 的正文：从第一个 `@@` 开始，不带 `diff --git` / `---` / `+++` 这些文件头。
    /// 二进制、没有内容变化（只改名或只改权限）、或总量用完时省略。
    public var patch: String?
    /// `patch` 被截断或因为总量用完被省略。
    public var truncated: Bool?

    public init(path: String, oldPath: String? = nil, status: Status, added: Int? = nil, removed: Int? = nil,
                binary: Bool? = nil, patch: String? = nil, truncated: Bool? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.added = added
        self.removed = removed
        self.binary = binary
        self.patch = patch
        self.truncated = truncated
    }
}
