import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

/// 这是本 app 唯一会改用户配置文件的地方，所以测试盯死三件事：
/// 别人的 hook 不能被碰、装两次等于装一次、卸载之后文件回到装之前的样子。
final class ClaudeHookInstallerTests: XCTestCase {
    private var root: URL!
    private var paths: ClaudePaths!
    private var support: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-hook-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = ClaudePaths(claudeHome: root.appendingPathComponent(".claude", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.claudeHome, withIntermediateDirectories: true)
        // 支持目录名里故意带空格，复刻真实的 `Application Support`。
        support = root.appendingPathComponent("Application Support/BotBus", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ settings: [String: Any]) throws {
        try ClaudeHookInstaller.writeSettings(settings, to: paths.settingsFile)
    }

    private func read() throws -> [String: Any] {
        try ClaudeHookInstaller.loadSettings(at: paths.settingsFile)
    }

    /// 用户机器上本来就挂着别的 hook（比如一个 PreToolUse 的自动批准脚本）。
    private let foreign: [String: Any] = [
        "hooks": [
            "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": "python3 ~/.claude/auto-approve-hook.py"]]]],
        ],
        "enabledPlugins": ["some-plugin"],
    ]

    func testInstallIsIdempotentAndPreservesOtherHooks() throws {
        try write(foreign)
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        let once = try read()
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        let twice = try read()

        // 装两次 == 装一次。
        XCTAssertEqual(NSDictionary(dictionary: once), NSDictionary(dictionary: twice), "安装必须幂等")

        let hooks = try XCTUnwrap(twice["hooks"] as? [String: Any])
        // 别人的 hook 一个字都没动。
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 1)
        let entries = try XCTUnwrap(preToolUse[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["command"] as? String, "python3 ~/.claude/auto-approve-hook.py")
        // 与 hooks 无关的键也原样留着。
        XCTAssertEqual(twice["enabledPlugins"] as? [String], ["some-plugin"])

        // 我们的五条都在，而且每条只有一份。
        for event in ClaudeHookInstaller.events {
            let matchers = try XCTUnwrap(hooks[event.rawValue] as? [[String: Any]])
            let ours = matchers.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
                .filter { ($0["command"] as? String)?.contains(ClaudeHookInstaller.marker) == true }
            XCTAssertEqual(ours.count, 1, "\(event.rawValue) 应当恰好一条我们的 hook")
        }
        XCTAssertTrue(ClaudeHookInstaller.isInstalled(paths: paths, supportDirectory: support))
    }

    /// 等人点头那条要给 Claude Code 留够时间，比脚本的 `--max-time 120` 宽一点。
    /// 老版本只挂了五个事件；新版本多了 StopFailure / SessionEnd。装过的自动补齐，别人的照旧，没装过的不碰。
    func testUpgradeCompletesAnOlderInstallOnly() throws {
        try write(foreign)
        XCTAssertFalse(try ClaudeHookInstaller.upgradeIfNeeded(paths: paths, supportDirectory: support),
                       "没装过就不替用户装")
        XCTAssertFalse(ClaudeHookInstaller.isInstalled(paths: paths, supportDirectory: support))

        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        var settings = try read()
        var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "StopFailure")
        hooks.removeValue(forKey: "SessionEnd")
        settings["hooks"] = hooks
        try write(settings)
        XCTAssertFalse(ClaudeHookInstaller.isInstalled(paths: paths, supportDirectory: support))

        XCTAssertTrue(try ClaudeHookInstaller.upgradeIfNeeded(paths: paths, supportDirectory: support))
        XCTAssertTrue(ClaudeHookInstaller.isInstalled(paths: paths, supportDirectory: support))
        let upgraded = try XCTUnwrap(try read()["hooks"] as? [String: Any])
        XCTAssertNotNil(upgraded["PreToolUse"], "别人的 hook 原样留着")
        XCTAssertEqual((upgraded["Stop"] as? [[String: Any]])?.count, 1, "不会多出第二条")
        XCTAssertFalse(try ClaudeHookInstaller.upgradeIfNeeded(paths: paths, supportDirectory: support),
                       "已经是全套就不再写文件")
    }

    func testPermissionRequestCarriesTimeout() throws {
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        let hooks = try XCTUnwrap(try read()["hooks"] as? [String: Any])
        let matchers = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let entry = try XCTUnwrap((matchers[0]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["timeout"] as? Int, ClaudeHookInstaller.permissionTimeoutSeconds)
        XCTAssertGreaterThan(ClaudeHookInstaller.permissionTimeoutSeconds, 1800, "必须比脚本的 --max-time 更宽")

        // 其余事件不该带 timeout（用默认值就好）。
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let stopEntry = try XCTUnwrap((stop[0]["hooks"] as? [[String: Any]])?.first)
        XCTAssertNil(stopEntry["timeout"])
    }

    func testInstallWritesBackupBeforeModifying() throws {
        try write(foreign)
        let before = try Data(contentsOf: paths.settingsFile)

        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        let backup = try Data(contentsOf: paths.backupFile)
        XCTAssertEqual(backup, before, "备份必须是改动之前的内容")

        // 第二次安装不能拿"已经含我们条目"的文件盖掉第一次的备份，否则后路就没了。
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        XCTAssertEqual(try Data(contentsOf: paths.backupFile), before, "备份只在第一次安装时写")
    }

    /// 原本就没有 settings.json 时不该凭空造一个备份。
    func testInstallWithoutExistingSettingsMakesNoBackup() throws {
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.backupFile.path))
        XCTAssertTrue(ClaudeHookInstaller.isInstalled(paths: paths, supportDirectory: support))
    }

    func testUninstallRestoresExactlyWhatWasThere() throws {
        try write(foreign)
        let before = try read()

        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        try ClaudeHookInstaller.uninstall(paths: paths, supportDirectory: support)

        XCTAssertEqual(NSDictionary(dictionary: try read()), NSDictionary(dictionary: before),
                       "卸载之后必须和装之前一模一样，不留空壳")
        XCTAssertFalse(ClaudeHookInstaller.isInstalled(paths: paths, supportDirectory: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClaudeHookInstaller.scriptURL(in: support).path),
                       "脚本也该删掉，别留一个没人调用的东西")
    }

    /// 本来就没有任何 hook 的用户：卸载后 `hooks` 键整个消失，而不是留一个空对象。
    func testUninstallRemovesEmptyHooksKey() throws {
        try write(["enabledPlugins": ["x"]])
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        try ClaudeHookInstaller.uninstall(paths: paths, supportDirectory: support)
        let after = try read()
        XCTAssertNil(after["hooks"])
        XCTAssertEqual(after["enabledPlugins"] as? [String], ["x"])
    }

    /// settings.json 是个数组或者坏掉了：宁可报错也不要覆盖。
    func testRefusesToTouchNonObjectSettings() throws {
        try Data("[1,2,3]".utf8).write(to: paths.settingsFile)
        XCTAssertThrowsError(try ClaudeHookInstaller.install(paths: paths, supportDirectory: support))
        XCTAssertEqual(try Data(contentsOf: paths.settingsFile), Data("[1,2,3]".utf8), "原文件不该被动")
    }

    /// 路径里有空格（`Application Support`）时命令必须带引号，否则 shell 会把它拆成两段。
    func testCommandQuotesPathsWithSpaces() throws {
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        let hooks = try XCTUnwrap(try read()["hooks"] as? [String: Any])
        let matchers = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let command = try XCTUnwrap(((matchers[0]["hooks"] as? [[String: Any]])?.first)?["command"] as? String)
        #if os(Windows)
        // Windows：绝对路径的 powershell.exe 加 `-File "<脚本>"`，路径整体在双引号里（Git Bash 与 cmd 都这么拆）。
        let script = ClaudeHookInstaller.scriptURL(in: support).path
        XCTAssertTrue(command.hasPrefix("\"") && command.contains("powershell.exe\""), command)
        XCTAssertTrue(command.hasSuffix("-File \"\(script)\""), "带空格的路径必须整体加引号：\(command)")
        #else
        XCTAssertTrue(command.hasPrefix("'") && command.hasSuffix("'"), "带空格的路径必须整体加引号：\(command)")
        #endif
        XCTAssertTrue(command.contains("Application Support"))
        XCTAssertTrue(command.contains(ClaudeHookInstaller.marker))
    }

    func testScriptIsExecutableAndNeverFails() throws {
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        #if !os(Windows)
        // Windows 的 hook 是经 powershell.exe 调的 .ps1，本身不是可执行文件。
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: ClaudeHookInstaller.scriptURL(in: support).path))
        #endif

        // 端口文件不在 = Agent 没跑。脚本必须安静地 exit 0，不能把 Claude Code 卡住或弄失败。
        let result = try runScript(payload: #"{"hook_event_name":"Stop","session_id":"s1"}"#)
        XCTAssertEqual(result.status, 0, "Agent 不在时脚本也必须 exit 0")
        XCTAssertTrue(result.output.isEmpty, "没有意见时不该有输出")
    }

    // MARK: - hook 密钥（v2 脚本）

    /// v1 脚本的原文（加 hook 密钥之前装在用户机器上的那份），升级检测要认得出它、兼容模式要照收它。
    private static let versionOneScript = """
    #!/bin/sh
    # WatchCrew 的 Claude Code hook。由 app 写入，可以整份删掉。
    # 把 hook 负载原样转给本机 Agent，再把 Agent 的回答原样吐回给 Claude Code。
    # 无论如何都 exit 0：这个脚本挂在 Claude Code 的主流程上，我们没资格让它失败。
    set -u

    PORT_FILE="$(dirname "$0")/agent.json"
    [ -f "$PORT_FILE" ] || exit 0
    PORT=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]\\{1,\\}\\).*/\\1/p' "$PORT_FILE")
    [ -n "$PORT" ] || exit 0

    PAYLOAD=$(cat)
    # 只有"等人点头"那条值得久等（30 分钟）；其余 3 秒足够，超了就当 Agent 不在。
    case "$PAYLOAD" in
      *'"PermissionRequest"'*) TIMEOUT=1800 ;;
      *) TIMEOUT=3 ;;
    esac

    RESPONSE=$(printf '%s' "$PAYLOAD" | curl -sS --max-time "$TIMEOUT" \\
      -H 'content-type: application/json' --data-binary @- \\
      "http://127.0.0.1:$PORT/hooks/claude" 2>/dev/null) || exit 0
    # 空回答 = 没有意见，Claude Code 回落到它自己的权限弹窗。
    [ -n "$RESPONSE" ] && printf '%s' "$RESPONSE"
    exit 0
    """

    #if os(Windows)
    /// Windows 版脚本：读同一个密钥文件、带同一个头；负载按原始字节进出；只有 ASCII（PowerShell 5.1 按 ANSI 读脚本）。
    func testScriptSendsSecretHeaderWithoutPuttingItOnTheCommandLine() {
        let script = ClaudeHookInstaller.script
        XCTAssertTrue(script.contains("script version \(ClaudeHookInstaller.scriptVersion)"))
        XCTAssertTrue(script.contains(LocalHookServer.SharedSecret.defaultFileName), "读服务端写的密钥文件")
        XCTAssertTrue(script.contains("Headers.Add('\(LocalHookServer.SharedSecret.headerName)'"))
        XCTAssertTrue(script.contains("OpenStandardInput") && script.contains("OpenStandardOutput"), "按字节读写，不经控制台代码页")
        XCTAssertFalse(script.contains("curl -"), "不调 curl（密钥文件名里的 .curlrc 不算）")
        XCTAssertTrue(script.unicodeScalars.allSatisfy(\.isASCII), "脚本只能有 ASCII")
    }
    #else
    func testScriptSendsSecretHeaderWithoutPuttingItOnTheCommandLine() {
        let script = ClaudeHookInstaller.script
        XCTAssertTrue(script.contains("脚本版本 \(ClaudeHookInstaller.scriptVersion)"))
        XCTAssertTrue(script.contains(LocalHookServer.SharedSecret.defaultFileName), "读服务端写的密钥文件")
        XCTAssertTrue(script.contains("--config \"$SECRET_FILE\""), "密钥经 curl --config 交过去，不进 argv")
        XCTAssertTrue(script.contains("curl -sS -f "), "非 2xx 当作没意见，错误 body 不吐给 Claude Code")
        XCTAssertFalse(script.contains("WatchCrew"))
    }
    #endif

    /// 装过 v1 脚本、settings 已是全套的机器：只把脚本换成新版，settings 一个字节不动。
    func testUpgradeRewritesAnOutdatedScriptOnly() throws {
        try write(foreign)
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        let settingsBefore = try Data(contentsOf: paths.settingsFile)
        let scriptURL = ClaudeHookInstaller.scriptURL(in: support)
        try Data(Self.versionOneScript.utf8).write(to: scriptURL)
        XCTAssertFalse(ClaudeHookInstaller.isScriptCurrent(in: support))

        XCTAssertTrue(try ClaudeHookInstaller.upgradeIfNeeded(paths: paths, supportDirectory: support))
        XCTAssertTrue(ClaudeHookInstaller.isScriptCurrent(in: support))
        XCTAssertEqual(try String(contentsOf: scriptURL, encoding: .utf8), ClaudeHookInstaller.script)
        #if !os(Windows)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptURL.path))
        #endif
        XCTAssertEqual(try Data(contentsOf: paths.settingsFile), settingsBefore, "只换脚本，不重写 settings")
        XCTAssertFalse(try ClaudeHookInstaller.upgradeIfNeeded(paths: paths, supportDirectory: support), "已是新版就不再动")
    }

    /// 没装过的用户，支持目录里就算躺着一个旧脚本也不替他装。
    func testUpgradeLeavesUninstalledUsersAlone() throws {
        try write(foreign)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(Self.versionOneScript.utf8).write(to: ClaudeHookInstaller.scriptURL(in: support))
        XCTAssertFalse(try ClaudeHookInstaller.upgradeIfNeeded(paths: paths, supportDirectory: support))
        XCTAssertFalse(ClaudeHookInstaller.isScriptCurrent(in: support))
    }

    /// 真跑一遍生成的脚本（sh + curl）打到真的 hook 服务器上：密钥对了才转发，
    /// 不对或没有（Linux 必须带）时 Claude Code 收到的是空输出，handler 一次都没被调用。
    func testGeneratedScriptRoundTripsThroughServerWithSecret() async throws {
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        let seen = Locked<[String]>([])
        let server = LocalHookServer(supportDirectory: support,
                                     sharedSecret: .init(enforcement: .required)) { request in
            seen.withLock { $0.append(request.header(LocalHookServer.SharedSecret.headerName) ?? "") }
            return .now(.json(#"{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}"#))
        }
        addTeardownBlock { await server.stop() }
        try await server.start()
        let active = await server.activeSecret
        let secret = try XCTUnwrap(active)

        let payload = #"{"hook_event_name":"Stop","session_id":"s1"}"#
        let answered = try runScript(payload: payload)
        XCTAssertEqual(answered.status, 0)
        XCTAssertEqual(answered.output, #"{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}"#)
        XCTAssertEqual(seen.current, [secret], "脚本带上了服务端这一轮的密钥")

        // 密钥文件被换成错的：403，脚本安静地什么都不输出。
        let secretFile = try XCTUnwrap(server.secretFileURL)
        try LocalHookServer.writePrivateFile(
            Data("header = \"\(LocalHookServer.SharedSecret.headerName): \(String(repeating: "0", count: 64))\"\n".utf8),
            to: secretFile)
        let wrong = try runScript(payload: payload)
        XCTAssertEqual(wrong.status, 0)
        XCTAssertEqual(wrong.output, "", "被拒时不能把错误吐给 Claude Code")

        // 密钥文件没了（等于老脚本不带头）：必须带的服务端照样拒。
        try FileManager.default.removeItem(at: secretFile)
        let missing = try runScript(payload: payload)
        XCTAssertEqual(missing.status, 0)
        XCTAssertEqual(missing.output, "")
        XCTAssertEqual(seen.current.count, 1, "被拒的请求没到 handler")
    }

    /// macOS 兼容模式：没有密钥文件（老版本 Agent）时脚本不带头，服务端照收；
    /// 同一个模式下 v1 老脚本（从不带头）也照收。
    func testGeneratedScriptWorksWithoutSecretInCompatibilityMode() async throws {
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        let seen = Locked<[String?]>([])
        let server = LocalHookServer(supportDirectory: support,
                                     sharedSecret: .init(enforcement: .whenPresent)) { request in
            seen.withLock { $0.append(request.header(LocalHookServer.SharedSecret.headerName)) }
            return .now(.json(#"{"ok":true}"#))
        }
        addTeardownBlock { await server.stop() }
        try await server.start()
        let secretFile = try XCTUnwrap(server.secretFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretFile.path))

        let withSecret = try runScript(payload: #"{"hook_event_name":"Stop"}"#)
        XCTAssertEqual(withSecret.output, #"{"ok":true}"#)

        try FileManager.default.removeItem(at: secretFile)
        let without = try runScript(payload: #"{"hook_event_name":"Stop"}"#)
        XCTAssertEqual(without.output, #"{"ok":true}"#)
        XCTAssertEqual(seen.current.count, 2)
        XCTAssertNotNil(seen.current[0])
        XCTAssertNil(seen.current[1], "没有密钥文件就不带头")

        // v1 老脚本是 sh 写的，只存在于 macOS / Linux 上。
        #if os(Windows)
        return
        #endif
        // 还没升级的 v1 脚本：从不带头，兼容模式下照收；必须带的模式下 403 且输出为空（不会把错误当 hook 输出）。
        try Data(Self.versionOneScript.utf8).write(to: ClaudeHookInstaller.scriptURL(in: support))
        let legacy = try runScript(payload: #"{"hook_event_name":"Stop"}"#)
        XCTAssertEqual(legacy.output, #"{"ok":true}"#)
        XCTAssertEqual(seen.current.count, 3)

        await server.stop()
        let strict = LocalHookServer(supportDirectory: support, sharedSecret: .init(enforcement: .required)) { _ in
            .now(.json(#"{"ok":true}"#))
        }
        addTeardownBlock { await strict.stop() }
        try await strict.start()
        let rejected = try runScript(payload: #"{"hook_event_name":"Stop"}"#)
        XCTAssertEqual(rejected.status, 0)
        XCTAssertEqual(rejected.output, "", "老脚本没有 curl -f，403 必须是空 body")
    }

    /// 跑支持目录里的脚本，stdin 喂 hook 负载，返回退出码与 stdout。
    private func runScript(payload: String) throws -> (status: Int32, output: String) {
        let process = Process()
        #if os(Windows)
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        process.executableURL = URL(fileURLWithPath: system + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
        process.arguments = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
                             ClaudeHookInstaller.scriptURL(in: support).path]
        #else
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [ClaudeHookInstaller.scriptURL(in: support).path]
        #endif
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
