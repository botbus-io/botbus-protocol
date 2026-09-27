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
        XCTAssertGreaterThan(ClaudeHookInstaller.permissionTimeoutSeconds, 120, "必须比脚本的 --max-time 更宽")

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
        XCTAssertTrue(command.hasPrefix("'") && command.hasSuffix("'"), "带空格的路径必须整体加引号：\(command)")
        XCTAssertTrue(command.contains("Application Support"))
        XCTAssertTrue(command.contains(ClaudeHookInstaller.marker))
    }

    func testScriptIsExecutableAndNeverFails() throws {
        try ClaudeHookInstaller.install(paths: paths, supportDirectory: support)
        let script = ClaudeHookInstaller.scriptURL(in: support)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))

        // 端口文件不在 = Agent 没跑。脚本必须安静地 exit 0，不能把 Claude Code 卡住或弄失败。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Agent 不在时脚本也必须 exit 0")
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "没有意见时不该有输出")
    }
}
