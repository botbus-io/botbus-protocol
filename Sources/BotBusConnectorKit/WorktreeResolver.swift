import Foundation
import os

/// 会话开在 git worktree 里时，它属于哪个项目（协议 2.7 `Task.worktreePath`）。
///
/// Claude app 每个会话开一个 `<仓库>/.claude/worktrees/<名字>`，Codex app 开在 `~/.codex/worktrees/<id>/<仓库名>`。
/// 按 cwd 分组的话，每个 worktree 都成了一个项目；这里把它们归回主仓库，续聊仍在原来的 worktree 里跑。
///
/// **尽量不读盘**：项目多半在「文稿」「桌面」里，菜单栏 app 一碰那里的文件，系统就会弹访问授权——
/// 只是看看手机上的会话列表，不该换来这么一个弹窗。所以：
/// - `<仓库>/.claude/worktrees/<名字>` 按路径直接归到 `<仓库>`，不读盘；目录删了也照样认得出。
/// - 其余只对路径里有一层 `worktrees` 目录的读盘：从工作目录往上、最多到那层 `worktrees` 为止找 `.git`。
///   它是**文件**、写着 `gitdir: <主仓库>/.git/worktrees/<名字>` 才算 worktree，主仓库按这个路径的形状取，
///   不再去读主仓库里的东西（它往往就在「文稿」里）。
/// - 两种都一样：工作目录是 worktree 里的子目录时，归到主仓库里的同一个子目录（`<wt>/web` → `<仓库>/web`），
///   和不在 worktree 里的会话按 cwd 分项目是同一个口径——手机选 `<仓库>/web` 开的 worktree 会话仍归在 `<仓库>/web` 下。`.git` 是目录（普通仓库）、指向 `.git/modules/…`（submodule）、
///   公共 git 目录不叫 `.git`（bare 仓库）都不算，原样当项目。
/// - 路径里没有 `worktrees` 的一概不查——手动 `git worktree add` 到别处的目录认不出来，原样当项目。
///
/// Codex 的 worktree 删了以后 `.git` 读不到、路径又看不出主仓库，所以认出来的对应关系记进 `worktrees.json`。
/// 没记过就已经删掉的（功能上线前的旧会话），按**同名**退回：Codex 的 worktree 目录就以仓库命名，
/// 在见过的主仓库与普通项目里恰好只有一个同名的，就归过去；同名的有两个以上不猜。这个结果只是推断，
/// 不进缓存也不落盘，每次按当时见过的目录重算。
/// 结果按路径缓存：`TaskStore` 每次盖章都会问一遍（Codex 每 2 秒对账一次）。
/// 读过盘仍认不出的路径过一会儿再查一次——目录可能刚建好、`.git` 还没写。
public final class WorktreeResolver: @unchecked Sendable {
    /// 认不出的路径多久后再查一次。
    public static let missRetryInterval: TimeInterval = 60
    /// `worktrees.json` 最多记多少条，超了丢最早认出的。
    public static let maxArchivedEntries = 1000
    public static let claudeWorktreesMarker = "/.claude/worktrees/"

    /// app 用的持久化位置，和 `artifacts.json` 放在一起。
    public static var defaultArchiveURL: URL {
        LocalHookServer.defaultSupportDirectory.appendingPathComponent("worktrees.json")
    }

    private static let log = Logger(subsystem: "io.botbus.agent", category: "worktrees")

    private struct File: Codable {
        var version: Int
        var worktrees: [Entry]
    }

    private struct Entry: Codable {
        var path: String
        var root: String
    }

    private let lock = NSLock()
    private let archiveURL: URL?
    private let now: @Sendable () -> Date
    /// worktree 目录 → 主仓库，按认出的先后排（持久化与淘汰用）。
    private var known: [String: String] = [:]
    private var order: [String] = []
    /// 认不出的路径 → 下次再查的时刻，以及那时目录还在不在（不在了才按同名退回）。
    private var misses: [String: (retryAt: Date, exists: Bool)] = [:]
    /// 见过的主仓库与普通项目，按目录名分组，给同名退回用。
    private var candidates: [String: Set<String>] = [:]

    /// - Parameter archiveURL: 对应关系的持久化文件；nil = 只在内存里（测试默认）。app 传 `defaultArchiveURL`。
    public init(archiveURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.archiveURL = archiveURL
        self.now = now
        guard let archiveURL, let data = try? Data(contentsOf: archiveURL) else { return }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            for entry in file.worktrees where known[entry.path] == nil {
                known[entry.path] = entry.root
                order.append(entry.path)
                noteCandidate(entry.root)
            }
        } catch {
            // 坏了就当没有：少几条对应关系只是那几个旧会话各自成项目，不能让 Agent 起不来。
            Self.log.warning("worktrees.json 读不出来，忽略：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 这个工作目录所在 worktree 的主仓库路径；不是 worktree 时为 nil。
    public func projectRoot(for path: String) -> String? {
        let path = Self.normalized(path)
        guard !path.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // 按形状认出来的每次都算得出来，不进缓存也不落盘。
        if let root = Self.resolveByShape(path) {
            noteCandidate(root)
            return root
        }
        guard Self.worktreesComponent(in: path) != nil else {
            // 普通目录：它自己可能就是某个已删 worktree 的主仓库，记下来给同名退回用。
            noteCandidate(path)
            return nil
        }
        if let root = known[path] { return root }
        if let miss = misses[path], now() < miss.retryAt { return miss.exists ? nil : sameNamedRoot(for: path) }

        guard let root = Self.resolveOnDisk(path) else {
            let exists = FileManager.default.fileExists(atPath: path)
            misses[path] = (now().addingTimeInterval(Self.missRetryInterval), exists)
            return exists ? nil : sameNamedRoot(for: path)
        }
        misses.removeValue(forKey: path)
        known[path] = root
        order.append(path)
        noteCandidate(root)
        if order.count > Self.maxArchivedEntries {
            for dropped in order.prefix(order.count - Self.maxArchivedEntries) { known.removeValue(forKey: dropped) }
            order.removeFirst(order.count - Self.maxArchivedEntries)
        }
        save()
        return root
    }

    // MARK: - 同名退回

    /// 调用方持有 `lock`。
    private func noteCandidate(_ path: String) {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return }
        candidates[name, default: []].insert(path)
    }

    /// 已删掉、没记过的 worktree：见过的目录里恰好只有一个和它同名时就是它。调用方持有 `lock`。
    private func sameNamedRoot(for path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard let matches = candidates[name], matches.count == 1, let root = matches.first, root != path else { return nil }
        return root
    }

    // MARK: - 解析

    /// Claude app 的 `<仓库>/.claude/worktrees/<名字>` → `<仓库>`，`…/<名字>/<子目录>` → `<仓库>/<子目录>`。只看路径。
    public static func resolveByShape(_ path: String) -> String? {
        guard let marker = path.range(of: claudeWorktreesMarker, options: .backwards),
              marker.upperBound < path.endIndex, marker.lowerBound > path.startIndex else { return nil }
        let repository = String(path[..<marker.lowerBound])
        let rest = path[marker.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return repository }
        let subpath = normalized(String(rest[rest.index(after: slash)...]))
        return subpath.isEmpty || subpath == "/" ? repository : repository + "/" + subpath
    }

    /// 路径里有一层 `worktrees` 时，从 `path` 往上找第一个 `.git`（不越过那层 `worktrees`），按它判断。
    /// `path` 是 worktree 里的子目录时，结果是主仓库里的同一个子目录。
    public static func resolveOnDisk(_ path: String, fileManager: FileManager = .default) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let marker = worktreesComponent(in: path) else { return nil }
        var isDirectory: ObjCBool = false
        var directory = URL(fileURLWithPath: path, isDirectory: true)
        /// 从 `path` 往上走过的目录名，由近及远。
        var climbed: [String] = []
        for _ in 0..<(components.count - marker - 1) {
            let dotGit = directory.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                // 第一个 `.git` 就决定了：是目录说明在普通仓库里（或 worktree 里嵌着的另一个仓库），不再往上找。
                guard !isDirectory.boolValue, let root = mainRepository(dotGitFile: dotGit) else { return nil }
                return climbed.isEmpty ? root : root + "/" + climbed.reversed().joined(separator: "/")
            }
            climbed.append(directory.lastPathComponent)
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// 路径里最后一层 `worktrees` 目录在 `pathComponents` 里的下标；它得是某一层父目录，不能是路径本身。
    public static func worktreesComponent(in path: String) -> Int? {
        URL(fileURLWithPath: path).pathComponents.dropLast().lastIndex(of: "worktrees")
    }

    /// 读 worktree 的 `.git` 文件：`gitdir: <主仓库>/.git/worktrees/<名字>`（新版 git 也可能写相对路径）。
    public static func mainRepository(dotGitFile: URL) -> String? {
        guard let content = try? String(contentsOf: dotGitFile, encoding: .utf8) else { return nil }
        let prefix = "gitdir:"
        guard let line = content.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let gitdirPath = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !gitdirPath.isEmpty else { return nil }
        let base = dotGitFile.deletingLastPathComponent()
        let gitdir = (gitdirPath.hasPrefix("/") ? URL(fileURLWithPath: gitdirPath, isDirectory: true)
                                                : base.appendingPathComponent(gitdirPath, isDirectory: true)).standardizedFileURL
        // submodule 指向 `.git/modules/<名字>`；bare 仓库的公共目录不叫 `.git`，没有"主仓库目录"可归。
        let worktrees = gitdir.deletingLastPathComponent()
        let commonDir = worktrees.deletingLastPathComponent()
        guard worktrees.lastPathComponent == "worktrees", commonDir.lastPathComponent == ".git" else { return nil }
        let root = normalized(commonDir.deletingLastPathComponent().path)
        return root.isEmpty || root == "/" ? nil : root
    }

    /// 去掉首尾空白与末尾的 `/`。
    public static func normalized(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - 持久化

    /// 调用方持有 `lock`。只在认出新的 worktree 时写，一次会话一条，不必合并。
    private func save() {
        guard let archiveURL else { return }
        let file = File(version: 1, worktrees: order.compactMap { path in known[path].map { Entry(path: path, root: $0) } })
        do {
            try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: archiveURL, options: .atomic)
        } catch {
            Self.log.warning("worktrees.json 写不进去：\(error.localizedDescription, privacy: .public)")
        }
    }
}
