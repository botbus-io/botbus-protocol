import Foundation
import BotBusProtocol

/// 哪些工作目录"不算项目"（协议 2.6 `Task.outsideProject`）。
///
/// 为什么在电脑上判定而不是手机上：主目录在哪、各 Agent 的默认工作区在哪，只有本机知道；
/// 手机只能对着 `/Users/xxx` 这种形状去猜，换一个平台就不成立。
///
/// 规则故意只认几个固定位置，不看目录里有没有 `.git`——很多正经项目并不用 git，
/// 按仓库判断会把它们误判成"不在项目中"。这里认的目录本身不算项目，**它们的子目录照常算**。
public struct OutsideProjectRule: Sendable, Equatable {
    public var homeDirectory: String
    /// 各来源的默认工作区（没指定目录时会话落在这里）。目前只有 OpenClaw 有。
    public var agentWorkspaces: [TaskSource: String]
    /// 手机新建项目时的存放目录（协议 2.6 `AgentInfo.projectsRoot`）。它本身不是项目，它下面的子文件夹才是。
    public var projectsRoot: String?

    /// 主目录下本身不算项目的那几个目录。
    public static let homeSubdirectories = ["Desktop", "Downloads", "Documents"]
    public static let systemDirectories = ["/", "/tmp", "/private/tmp"]

    public init(homeDirectory: String = NSHomeDirectory(), agentWorkspaces: [TaskSource: String] = [:],
                projectsRoot: String? = nil) {
        self.homeDirectory = homeDirectory
        self.agentWorkspaces = agentWorkspaces
        self.projectsRoot = projectsRoot
    }

    /// 这个路径是否不算项目。空串（没有目录）也算。
    public func contains(_ path: String) -> Bool {
        let home = Self.normalized(homeDirectory, home: "")
        let path = Self.normalized(path, home: home)
        if path.isEmpty || Self.systemDirectories.contains(path) { return true }
        if !home.isEmpty {
            if path == home { return true }
            if Self.homeSubdirectories.contains(where: { path == home + "/" + $0 }) { return true }
        }
        let others = Array(agentWorkspaces.values) + (projectsRoot.map { [$0] } ?? [])
        return others.contains { !$0.isEmpty && Self.normalized($0, home: home) == path }
    }

    /// 去掉首尾空白与末尾的 `/`，开头的 `~` 按规则里的主目录展开（不读进程环境，测试才能注入）。根目录 `/` 保持原样。
    public static func normalized(_ path: String, home: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty, path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
