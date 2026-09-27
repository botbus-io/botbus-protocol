import Foundation
import BotBusConnectorKit

/// 把 BotBus 的 hook 条目并进 `~/.claude/settings.json`，以及原样撤回。
///
/// **这是本 app 唯一会改用户配置文件的地方**，所以三条纪律写死在这里：
/// 1. 写之前整份备份到 `settings.json.botbus.bak`；
/// 2. 只认领带 `marker` 的条目，别人的 hook 一个字都不碰（用户机器上本来就可能挂着 `PreToolUse`）；
/// 3. 幂等——装两次和装一次结果相同，卸载之后文件回到装之前的样子。
///
/// 合并与撤回是纯函数（`merged` / `removed`），文件读写是另一层：前者有测试，后者只做 I/O。
public enum ClaudeHookInstaller {
    /// 认领自己条目的唯一凭据。脚本文件名里带着它，所以任何 `command` 含有它的条目都是我们写的，
    /// 就算用户把支持目录搬了也仍然认得出来。
    public static let marker = "botbus-claude-hook"
    public static let scriptName = "botbus-claude-hook.sh"

    /// 要挂的事件。`matcher` 一律为空串——按 spec，过滤放在 Agent 侧做。
    public static let events: [ClaudeHookEvent.Kind] = [
        .sessionStart, .userPromptSubmit, .permissionRequest, .notification, .stop, .stopFailure, .sessionEnd,
    ]

    /// `PermissionRequest` 这条要等手机上点头，给 Claude Code 的超时必须比脚本的 `--max-time 120` 宽一点，
    /// 否则 Claude Code 先放弃、脚本的回答就没人收了。
    public static let permissionTimeoutSeconds = 130

    // MARK: - 纯函数：合并与撤回

    /// 把本工具的条目并进一份已有的 settings。幂等；不动任何不带 `marker` 的条目。
    public static func merged(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        var result = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var matchers = hooks[event.rawValue] as? [[String: Any]] ?? []
            // 先撤掉自己的旧条目再加新的：脚本路径变了也不会留下两条。
            matchers = matchers.compactMap { stripOurs(from: $0) }
            matchers.append(["matcher": "", "hooks": [ourEntry(event: event, scriptPath: scriptPath)]])
            hooks[event.rawValue] = matchers
        }
        result["hooks"] = hooks
        return result
    }

    /// 把本工具的条目撤掉，别人的原样留下。空掉的 matcher 与空掉的事件键一并删除，
    /// 让文件回到装之前的样子而不是留一堆空壳。
    public static func removed(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooks {
            guard let matchers = value as? [[String: Any]] else { continue }
            let kept = matchers.compactMap { stripOurs(from: $0) }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        if hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooks
        }
        return result
    }

    /// 这份 settings 里已经装好了指向 `scriptPath` 的全套条目？
    public static func isInstalled(in settings: [String: Any], scriptPath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            guard let matchers = hooks[event.rawValue] as? [[String: Any]] else { return false }
            return matchers.contains { matcher in
                guard let entries = matcher["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { ($0["command"] as? String) == command(scriptPath) }
            }
        }
    }

    /// 从一个 matcher 里摘掉我们的 hook。摘完没剩下任何 hook 的 matcher 整条丢弃（返回 nil）。
    private static func stripOurs(from matcher: [String: Any]) -> [String: Any]? {
        guard let entries = matcher["hooks"] as? [[String: Any]] else { return matcher }
        let kept = entries.filter { !isOurs($0) }
        if kept.isEmpty { return nil }
        var result = matcher
        result["hooks"] = kept
        return result
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(marker) ?? false
    }

    private static func ourEntry(event: ClaudeHookEvent.Kind, scriptPath: String) -> [String: Any] {
        var entry: [String: Any] = ["type": "command", "command": command(scriptPath)]
        if event == .permissionRequest { entry["timeout"] = permissionTimeoutSeconds }
        return entry
    }

    /// 支持目录里有空格（`Application Support`），命令行必须带引号。
    /// 路径里的单引号按 shell 的老办法转义，免得拼出一条能被注入的命令。
    static func command(_ scriptPath: String) -> String {
        "'" + scriptPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 文件读写

    public enum Failure: LocalizedError {
        case settingsNotJSONObject(String)

        public var errorDescription: String? {
            switch self {
            case .settingsNotJSONObject(let path): return "\(path) 不是一个 JSON 对象，没敢改它"
            }
        }
    }

    /// 读 settings.json。文件不存在当成空对象（Claude Code 自己也是这么处理的）。
    public static func loadSettings(at url: URL) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: url.path), !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { throw Failure.settingsNotJSONObject(url.path) }
        return dictionary
    }

    /// 原子写回。`sortedKeys` 让每次写出的字节稳定，用户 diff 自己的配置时不会看到无谓的抖动。
    public static func writeSettings(_ settings: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// 装 hook：写脚本 → 备份 settings → 合并写回。
    ///
    /// 备份**先于**任何修改，且只在原文件存在时才做；已经有备份就不覆盖——
    /// 第二次安装的"原文件"已经含我们的条目了，拿它盖掉第一次的备份等于把后路抹掉。
    public static func install(paths: ClaudePaths, supportDirectory: URL) throws {
        let scriptPath = try writeScript(into: supportDirectory)
        let settings = try loadSettings(at: paths.settingsFile)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: paths.settingsFile.path),
           !fileManager.fileExists(atPath: paths.backupFile.path) {
            try? fileManager.copyItem(at: paths.settingsFile, to: paths.backupFile)
        }
        try writeSettings(merged(into: settings, scriptPath: scriptPath), to: paths.settingsFile)
    }

    /// 卸载：精确撤回我们的条目。脚本文件一并删掉，免得留一个没人调用的东西在用户目录里。
    public static func uninstall(paths: ClaudePaths, supportDirectory: URL) throws {
        let settings = try loadSettings(at: paths.settingsFile)
        try writeSettings(removed(from: settings), to: paths.settingsFile)
        try? FileManager.default.removeItem(at: scriptURL(in: supportDirectory))
    }

    /// 老版本装的是少几个事件的旧套（`StopFailure` / `SessionEnd` 是后来补的）。用户装过——settings 里
    /// 有我们的条目——却不是全套时，按当前版本重装一遍；没装过的不碰，装 hook 要用户在设置里点头。
    /// 返回是否重装了。
    @discardableResult
    public static func upgradeIfNeeded(paths: ClaudePaths, supportDirectory: URL) throws -> Bool {
        let settings = try loadSettings(at: paths.settingsFile)
        guard hasAnyOfOurs(in: settings),
              !isInstalled(in: settings, scriptPath: scriptURL(in: supportDirectory).path) else { return false }
        try install(paths: paths, supportDirectory: supportDirectory)
        return true
    }

    /// 这份 settings 里有没有任何一条本工具的 hook。
    static func hasAnyOfOurs(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains { matcher in
                (matcher["hooks"] as? [[String: Any]])?.contains(where: isOurs) ?? false
            } ?? false
        }
    }

    public static func isInstalled(paths: ClaudePaths, supportDirectory: URL) -> Bool {
        guard let settings = try? loadSettings(at: paths.settingsFile) else { return false }
        return isInstalled(in: settings, scriptPath: scriptURL(in: supportDirectory).path)
    }

    public static func scriptURL(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(scriptName)
    }

    @discardableResult
    static func writeScript(into supportDirectory: URL) throws -> String {
        let url = scriptURL(in: supportDirectory)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// 转发脚本。三条硬要求：**永远 exit 0**、Agent 不在就安静退出、除了 `PermissionRequest`
    /// 都只等 3 秒——它挂在 Claude Code 的主流程上，绝不能因为我们的 app 没开就把用户卡住。
    static let script = """
    #!/bin/sh
    # WatchCrew 的 Claude Code hook。由 app 写入，可以整份删掉。
    # 把 hook 负载原样转给本机 Agent，再把 Agent 的回答原样吐回给 Claude Code。
    # 无论如何都 exit 0：这个脚本挂在 Claude Code 的主流程上，我们没资格让它失败。
    set -u

    PORT_FILE="$(dirname "$0")/\(LocalHookServer.portFileName)"
    [ -f "$PORT_FILE" ] || exit 0
    PORT=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]\\{1,\\}\\).*/\\1/p' "$PORT_FILE")
    [ -n "$PORT" ] || exit 0

    PAYLOAD=$(cat)
    # 只有"等人点头"那条值得久等；其余 3 秒足够，超了就当 Agent 不在。
    case "$PAYLOAD" in
      *'"\(ClaudeHookEvent.Kind.permissionRequest.rawValue)"'*) TIMEOUT=120 ;;
      *) TIMEOUT=3 ;;
    esac

    RESPONSE=$(printf '%s' "$PAYLOAD" | curl -sS --max-time "$TIMEOUT" \\
      -H 'content-type: application/json' --data-binary @- \\
      "http://127.0.0.1:$PORT/hooks/claude" 2>/dev/null) || exit 0
    # 空回答 = 没有意见，Claude Code 回落到它自己的权限弹窗。
    [ -n "$RESPONSE" ] && printf '%s' "$RESPONSE"
    exit 0
    """
}
