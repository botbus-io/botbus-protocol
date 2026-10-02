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
    #if os(Windows)
    /// Windows 上是 PowerShell 脚本（不依赖 Git Bash 里有没有 curl / sed），经 `powershell.exe -File` 调用。
    public static let scriptName = "botbus-claude-hook.ps1"
    #else
    public static let scriptName = "botbus-claude-hook.sh"
    #endif

    /// 要挂的事件。`matcher` 一律为空串——按 spec，过滤放在 Agent 侧做。
    public static let events: [ClaudeHookEvent.Kind] = [
        .sessionStart, .userPromptSubmit, .permissionRequest, .notification, .stop, .stopFailure, .sessionEnd,
    ]

    /// `PermissionRequest` 这条要等手机上点头，给 Claude Code 的超时必须比脚本的 `--max-time` 宽一点，
    /// 否则 Claude Code 先放弃、脚本的回答就没人收了。30 分钟 + 10 秒余量。
    public static let permissionTimeoutSeconds = 1810

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
    ///
    /// Windows：Claude Code 可能经 Git Bash 也可能经 cmd 跑这条命令，两边都认的写法是绝对路径的 `powershell.exe`
    /// 加双引号包住的脚本路径（Windows 路径里不可能有 `"`；双引号里的 `\` 在 bash 里也原样保留）。
    static func command(_ scriptPath: String) -> String {
        #if os(Windows)
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let powershell = system + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
        return "\"\(powershell)\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"\(scriptPath)\""
        #else
        return "'" + scriptPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        #endif
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

    /// 用户装过——settings 里有我们的条目——才升级；没装过的不碰，装 hook 要用户在设置里点头。两种旧装：
    /// - settings 不是全套（老版本少 `StopFailure` / `SessionEnd`）：按当前版本重装一遍；
    /// - 脚本不是当前版本（例如 v1 不带 hook 密钥）：只重写脚本，settings 一个字节不动。
    /// 返回是否改了东西。
    @discardableResult
    public static func upgradeIfNeeded(paths: ClaudePaths, supportDirectory: URL) throws -> Bool {
        let settings = try loadSettings(at: paths.settingsFile)
        guard hasAnyOfOurs(in: settings) else { return false }
        if !isInstalled(in: settings, scriptPath: scriptURL(in: supportDirectory).path) {
            try install(paths: paths, supportDirectory: supportDirectory)
            return true
        }
        guard !isScriptCurrent(in: supportDirectory) else { return false }
        try writeScript(into: supportDirectory)
        return true
    }

    /// 支持目录里的脚本和当前版本逐字节相同？整份比较：模板改了哪怕一个字（`scriptVersion` 每次改都要加一）都算旧。
    static func isScriptCurrent(in supportDirectory: URL) -> Bool {
        FileManager.default.contents(atPath: scriptURL(in: supportDirectory).path) == Data(script.utf8)
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
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        #endif
        return url.path
    }

    /// 脚本模板的版本，写在脚本第二行。改模板就加一：`upgradeIfNeeded` 靠整份比对发现旧脚本，
    /// 这个数字是给人看的（用户打开脚本知道是哪一版）。
    /// v1：只带端口；v2：带 hook 密钥（`X-BotBus-Hook-Secret`）、`curl -f`。
    static let scriptVersion = 2

    /// 转发脚本。三条硬要求：**永远 exit 0**、Agent 不在就安静退出、除了 `PermissionRequest`
    /// 都只等 3 秒——它挂在 Claude Code 的主流程上，绝不能因为我们的 app 没开就把用户卡住。
    ///
    /// 密钥文件是一行 curl 配置，交给 `curl --config`：密钥不进命令行（同机别的用户 `ps` 看得见 argv）。
    /// 文件不在（老版本 Agent 在跑）就不带头，macOS 上的服务端照样收。
    /// `-f`：非 2xx（例如 403）一律当作 Agent 没意见，错误 body 不会被当成 hook 输出吐给 Claude Code。
    #if !os(Windows)
    static let script = """
    #!/bin/sh
    # BotBus 的 Claude Code hook（脚本版本 \(scriptVersion)）。由 app 写入，可以整份删掉。
    # 把 hook 负载原样转给本机 Agent，再把 Agent 的回答原样吐回给 Claude Code。
    # 无论如何都 exit 0：这个脚本挂在 Claude Code 的主流程上，我们没资格让它失败。
    set -u

    DIR=$(dirname "$0")
    PORT_FILE="$DIR/\(LocalHookServer.portFileName)"
    [ -f "$PORT_FILE" ] || exit 0
    PORT=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]\\{1,\\}\\).*/\\1/p' "$PORT_FILE")
    [ -n "$PORT" ] || exit 0

    # Agent 每次启动换一个随机密钥（请求头 \(LocalHookServer.SharedSecret.headerName)），只有本用户读得到。
    SECRET_FILE="$DIR/\(LocalHookServer.SharedSecret.defaultFileName)"
    if [ -r "$SECRET_FILE" ]; then set -- --config "$SECRET_FILE"; else set --; fi

    PAYLOAD=$(cat)
    # 只有"等人点头"那条值得久等（30 分钟）；其余 3 秒足够，超了就当 Agent 不在。
    case "$PAYLOAD" in
      *'"\(ClaudeHookEvent.Kind.permissionRequest.rawValue)"'*) TIMEOUT=1800 ;;
      *) TIMEOUT=3 ;;
    esac

    RESPONSE=$(printf '%s' "$PAYLOAD" | curl -sS -f --noproxy '*' --max-time "$TIMEOUT" "$@" \\
      -H 'content-type: application/json' --data-binary @- \\
      "http://127.0.0.1:$PORT/hooks/claude" 2>/dev/null) || exit 0
    # 空回答 = 没有意见，Claude Code 回落到它自己的权限弹窗。
    [ -n "$RESPONSE" ] && printf '%s' "$RESPONSE"
    exit 0
    """
    #else
    /// Windows 版：同样三条硬要求。只用 Windows 自带的 PowerShell 5.1 与 .NET，不依赖 curl。
    ///
    /// - 负载按原始字节读 stdin、按原始字节写 stdout：`[Console]::In` 会按控制台代码页解码，中文会坏。
    /// - 密钥文件是那一行 curl 配置（与 macOS / Linux 同一个文件），这里解析出头的值带上。
    /// - 非 2xx（例如 403）`GetResponse()` 直接抛异常，落进 catch，什么也不输出——与 `curl -f` 一样。
    /// - 脚本内容只用 ASCII：PowerShell 5.1 按 ANSI 代码页读没有 BOM 的脚本。
    static let script = """
    # BotBus Claude Code hook (script version \(scriptVersion)). Written by BotBus; safe to delete.
    # Forwards the hook payload to the local BotBus agent and prints its answer back to Claude Code.
    # Always exits 0: this runs inside Claude Code's main loop and must never make it fail.
    $ErrorActionPreference = 'Stop'
    try {
        $dir = Split-Path -Parent $MyInvocation.MyCommand.Path
        $portFile = Join-Path $dir '\(LocalHookServer.portFileName)'
        if (-not (Test-Path -LiteralPath $portFile)) { exit 0 }
        $port = [int]((Get-Content -LiteralPath $portFile -Raw | ConvertFrom-Json).port)
        if ($port -le 0) { exit 0 }

        $stdin = [Console]::OpenStandardInput()
        $buffer = New-Object System.IO.MemoryStream
        $stdin.CopyTo($buffer)
        $payload = $buffer.ToArray()
        $text = [System.Text.Encoding]::UTF8.GetString($payload)
        # Only the "wait for the phone" hook is worth waiting for (30 minutes); 3 seconds for the rest.
        $timeout = 3
        if ($text.Contains('"\(ClaudeHookEvent.Kind.permissionRequest.rawValue)"')) { $timeout = 1800 }

        $request = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$port/hooks/claude")
        $request.Method = 'POST'
        $request.ContentType = 'application/json'
        $request.Proxy = $null
        $request.Timeout = $timeout * 1000
        $request.ReadWriteTimeout = $timeout * 1000
        $secretFile = Join-Path $dir '\(LocalHookServer.SharedSecret.defaultFileName)'
        if (Test-Path -LiteralPath $secretFile) {
            $line = Get-Content -LiteralPath $secretFile -Raw
            if ($line -match '\(LocalHookServer.SharedSecret.headerName):\\s*([^"\\s]+)') {
                $request.Headers.Add('\(LocalHookServer.SharedSecret.headerName)', $Matches[1])
            }
        }
        $request.ContentLength = $payload.Length
        $body = $request.GetRequestStream()
        $body.Write($payload, 0, $payload.Length)
        $body.Close()

        $response = $request.GetResponse()
        $answer = New-Object System.IO.MemoryStream
        $response.GetResponseStream().CopyTo($answer)
        $response.Close()
        # An empty answer means "no opinion": Claude Code falls back to its own permission prompt.
        if ($answer.Length -gt 0) {
            $out = [Console]::OpenStandardOutput()
            $out.Write($answer.ToArray(), 0, [int]$answer.Length)
            $out.Flush()
        }
    } catch {
    }
    exit 0
    """
    #endif
}
