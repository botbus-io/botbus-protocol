import Foundation
import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class AcpDiscoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }

    private let catalog = [
        AcpRegistryEntry(id: "gemini", name: "Gemini CLI", binaries: ["gemini"], args: ["--acp"], defaultEnabled: true),
        AcpRegistryEntry(id: "goose", name: "goose", binaries: ["goose"], args: ["acp"], defaultEnabled: true),
        AcpRegistryEntry(id: "codex-acp", name: "Codex", binaries: ["codex-acp"], args: [], defaultEnabled: true),
    ]

    private func locate(_ name: String) -> String? {
        ["gemini": "/opt/homebrew/bin/gemini", "codex-acp": "/usr/local/bin/codex-acp", "my-agent": "/usr/local/bin/my-agent"][name]
    }

    func testValidManifestWithAbsoluteCommand() throws {
        try write("my-agent.json", #"{"id":"my-agent","name":"My Agent","command":"\#(anyExecutableJSON)","args":["-c","exit 0"],"env":{"A":"1"}}"#)
        let result = AcpDiscovery.discover(manifestDirectory: directory, catalog: [], locate: locate)
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.agents, [AcpAgentSpec(id: "my-agent", name: "My Agent", executable: anyExecutablePath,
                                                    arguments: ["-c", "exit 0"], environment: ["A": "1"],
                                                    origin: .manifest, defaultEnabled: true)])
    }

    func testManifestWithoutCommandIsReverseOnly() throws {
        try write("daemon.json", #"{"id":"daemon","name":"Daemon"}"#)
        let spec = try XCTUnwrap(AcpDiscovery.discover(manifestDirectory: directory, catalog: [], locate: locate).agents.first)
        XCTAssertNil(spec.executable)
    }

    func testRelativeCommandIsLocated() throws {
        try write("my-agent.json", #"{"id":"my-agent","name":"My Agent","command":"my-agent"}"#)
        let spec = try XCTUnwrap(AcpDiscovery.discover(manifestDirectory: directory, catalog: [], locate: locate).agents.first)
        XCTAssertEqual(spec.executable, "/usr/local/bin/my-agent")
    }

    func testBadManifestsAreReported() throws {
        try write("broken.json", "{not json")
        try write("wrong-name.json", #"{"id":"other","name":"X"}"#)
        try write("BadId.json", #"{"id":"BadId","name":"X"}"#)
        try write("codex.json", #"{"id":"codex","name":"假 Codex"}"#)
        try write("missing.json", #"{"id":"missing","name":"X","command":"nope"}"#)
        try write("README.md", "不是清单")
        let result = AcpDiscovery.discover(manifestDirectory: directory, catalog: [], locate: locate)
        XCTAssertEqual(result.agents, [])
        XCTAssertEqual(Set(result.problems.map { ($0.file as NSString).lastPathComponent }),
                       ["broken.json", "wrong-name.json", "BadId.json", "codex.json", "missing.json"])
        XCTAssertTrue(result.problems.contains { $0.reason.contains("内置") }, "占用一档的 id 要说清楚")
    }

    func testRegistryAgentsAreFoundAndAdaptersSkipped() throws {
        let result = AcpDiscovery.discover(manifestDirectory: directory, catalog: catalog, locate: locate)
        XCTAssertEqual(result.agents.map(\.id), ["gemini"], "goose 没装；codex-acp 是一档的适配器")
        XCTAssertEqual(result.agents.first?.executable, "/opt/homebrew/bin/gemini")
        XCTAssertEqual(result.agents.first?.arguments, ["--acp"])
        XCTAssertEqual(result.agents.first?.origin, .registry)
    }

    /// npx 分发的条目光靠名字找不够：PATH 上可能装着同名的无关程序（`nova` 的 npm 包里那个可执行
    /// 文件叫 `compass`，跟 Sass 的老工具同名）。`AcpDiscovery.discover` 必须确认 `locate` 找到的
    /// 可执行文件（跟软链接之后）真的落在这个 npm 包的 `node_modules/` 目录下，才把它当成这个 agent。
    func testRegistryVerifiesNpmPackageBeforeTrustingBinary() throws {
        try skipPOSIXScriptOnWindows()
        let packageBinary = directory.appendingPathComponent("lib/node_modules/@google/gemini-cli/bin/gemini")
        try FileManager.default.createDirectory(at: packageBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: packageBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packageBinary.path)

        // 装好后 PATH 上真正找到的那个 bin 其实是个软链接，指回 node_modules 里的真实文件。
        let symlinkDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        let symlink = symlinkDirectory.appendingPathComponent("gemini")
        try makeSymbolicLink(at: symlink, withDestinationURL: packageBinary)

        // 同名但跟这个 npm 包毫无关系的可执行文件——比如用户自己装的另一个叫 gemini 的脚本。
        let unrelatedDirectory = directory.appendingPathComponent("bin2", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)
        let unrelated = unrelatedDirectory.appendingPathComponent("gemini")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unrelated.path)

        let entry = AcpRegistryEntry(id: "gemini", name: "Gemini CLI", binaries: ["gemini"], args: ["--acp"],
                                     defaultEnabled: true, npmPackage: "@google/gemini-cli")
        let manifestDirectory = directory.appendingPathComponent("no-manifests-here")

        let accepted = AcpDiscovery.discover(manifestDirectory: manifestDirectory, catalog: [entry]) { _ in symlink.path }
        XCTAssertEqual(accepted.agents.map(\.executable), [symlink.path], "落在这个包 node_modules 下的软链接应该被采信")

        let rejected = AcpDiscovery.discover(manifestDirectory: manifestDirectory, catalog: [entry]) { _ in unrelated.path }
        XCTAssertEqual(rejected, AcpDiscoveryResult(agents: [], problems: []), "不在这个包 node_modules 下的同名可执行文件不该被当成这个 agent")
    }

    /// Windows 上 npm 全局装的命令不是软链接，而是 `%APPDATA%\npm` 里的 `.cmd` 包装脚本，
    /// 包本身在同目录的 `node_modules\<包名>\` 下；`AgentBinary.detect` 交出来的是 `gemini.cmd`。
    /// 这种包装得按它引用的包来认，不然每个 npm 分发的注册表条目在 Windows 上都会被悄悄跳过。
    func testRegistryAcceptsWindowsNpmCmdShim() throws {
        #if !os(Windows)
        throw XCTSkip("只有 Windows 的 npm 全局安装是 .cmd 包装")
        #else
        let fileManager = FileManager.default
        let npmDirectory = directory.appendingPathComponent("npm", isDirectory: true)
        let packageDirectory = npmDirectory.appendingPathComponent("node_modules/@google/gemini-cli/bundle", isDirectory: true)
        try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try Data("console.log('hi')\n".utf8).write(to: packageDirectory.appendingPathComponent("gemini.js"))
        // npm（cmd-shim）生成的包装脚本原样。
        let shim = npmDirectory.appendingPathComponent("gemini.cmd")
        try Data(#"""
            @ECHO off\#r
            GOTO start\#r
            :find_dp0\#r
            SET dp0=%~dp0\#r
            EXIT /b\#r
            :start\#r
            SETLOCAL\#r
            CALL :find_dp0\#r
            \#r
            IF EXIST "%dp0%\node.exe" (\#r
              SET "_prog=%dp0%\node.exe"\#r
            ) ELSE (\#r
              SET "_prog=node"\#r
              SET PATHEXT=%PATHEXT:;.JS;=;%\#r
            )\#r
            \#r
            endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\node_modules\@google\gemini-cli\bundle\gemini.js" %*\#r

            """#.utf8).write(to: shim)

        // 同目录下另一个同名包装，但引用的是别的包——比如用户自己装的另一个叫 gemini 的 npm 包。
        let otherDirectory = directory.appendingPathComponent("other", isDirectory: true)
        try fileManager.createDirectory(at: otherDirectory.appendingPathComponent("node_modules/@google/gemini-cli", isDirectory: true),
                                        withIntermediateDirectories: true)
        let unrelatedShim = otherDirectory.appendingPathComponent("gemini.cmd")
        try Data(#"@"%~dp0\node_modules\gemini-lookalike\bin\gemini.js" %*"#.utf8).write(to: unrelatedShim)

        // 包里直接带的原生 `.exe`（路径里就有 `node_modules\<包名>\`），用 Windows 分隔符写。
        let nativeDirectory = npmDirectory.appendingPathComponent("node_modules/@github/copilot/bin", isDirectory: true)
        try fileManager.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        let native = nativeDirectory.appendingPathComponent("copilot.exe")
        try Data().write(to: native)

        let entry = AcpRegistryEntry(id: "gemini", name: "Gemini CLI", binaries: ["gemini"], args: ["--acp"],
                                     defaultEnabled: true, npmPackage: "@google/gemini-cli")
        let copilot = AcpRegistryEntry(id: "github-copilot-cli", name: "GitHub Copilot", binaries: ["copilot"], args: ["--acp"],
                                       defaultEnabled: true, npmPackage: "@github/copilot")
        let windowsPath = { (url: URL) in url.withUnsafeFileSystemRepresentation { String(cString: $0!) } }

        XCTAssertEqual(AcpDiscovery.locateVerifiedBinary(for: entry) { _ in windowsPath(shim) }, windowsPath(shim),
                       "引用了这个包的 npm .cmd 包装应该被采信")
        XCTAssertNil(AcpDiscovery.locateVerifiedBinary(for: entry) { _ in windowsPath(unrelatedShim) },
                     "引用别的包的同名 .cmd 包装不该被当成这个 agent（旁边有没有这个包的目录都一样）")
        XCTAssertEqual(AcpDiscovery.locateVerifiedBinary(for: copilot) { _ in windowsPath(native) }, windowsPath(native),
                       "落在这个包 node_modules 下的 .exe 用反斜杠写也要认")
        #endif
    }

    func testManifestWinsOverRegistry() throws {
        try write("gemini.json", #"{"id":"gemini","name":"我的 Gemini","command":"\#(anyExecutableJSON)"}"#)
        let result = AcpDiscovery.discover(manifestDirectory: directory, catalog: catalog, locate: locate)
        XCTAssertEqual(result.agents.map(\.name), ["我的 Gemini"])
        XCTAssertEqual(result.agents.first?.origin, .manifest)
    }

    func testMissingDirectoryIsEmpty() {
        let result = AcpDiscovery.discover(manifestDirectory: directory.appendingPathComponent("nope"), catalog: [], locate: locate)
        XCTAssertEqual(result, AcpDiscoveryResult(agents: [], problems: []))
    }

    func testBundledSnapshotHasNoReservedIds() {
        XCTAssertTrue(AcpRegistrySnapshot.entries.allSatisfy { !AcpDiscovery.reservedIds.contains($0.id) })
        XCTAssertTrue(AcpRegistrySnapshot.entries.allSatisfy { ConnectorRef.isValidAcpId($0.id) })
    }

    /// `gemini` 稳定是 npx 分发的（`@google/gemini-cli`）；用它守住脚本没漏打 `npmPackage`——
    /// 漏了的话 `AcpDiscovery` 就没法在装到本机后校验它，退化回只按名字命中。
    /// 其余条目里只要写了 `npmPackage`，也得是个像样的包名（非空、不含空白）。
    func testBundledSnapshotNpmEntriesCarryNpmPackage() {
        let gemini = AcpRegistrySnapshot.entries.first { $0.id == "gemini" }
        XCTAssertEqual(gemini?.npmPackage, "@google/gemini-cli")
        for entry in AcpRegistrySnapshot.entries {
            guard let npmPackage = entry.npmPackage else { continue }
            XCTAssertFalse(npmPackage.isEmpty, "\(entry.id) 的 npmPackage 不能是空字符串")
            XCTAssertFalse(npmPackage.contains(where: \.isWhitespace), "\(entry.id) 的 npmPackage 不能带空白：\(npmPackage)")
        }
    }

    func testWatcherFiresWhenManifestAppears() async throws {
        let fired = Locked(0)
        let watcher = AcpManifestWatcher(directory: directory, debounce: 0.05) { fired.withLock { $0 += 1 } }
        watcher.start()
        defer { watcher.stop() }
        try write("my-agent.json", #"{"id":"my-agent","name":"My Agent"}"#)
        await assertEventually { fired.withLock { $0 } >= 1 }
    }

    /// kqueue 盯目录 fd 只在目录本身增删条目时触发，编辑器保存、安装器 `cp new.json x.json` 这类
    /// 原地重写已存在文件不会触发；FSEvents 的 `kFSEventStreamCreateFlagFileEvents` 能收到。
    ///
    /// 写文件必须在 `start()` 之后、且隔够久再重写：`start()` 之前写的文件，FSEvents 偶尔会把这次写
    /// 也算进流建立后的第一批事件里（间隔 < 5ms 左右），这时第一次 `assertEventually` 会因为这次
    /// "旧" 写入而提前满足，之后 `fired` 清零、真正的原地重写就测不出东西；间隔一大（CI 负载高时）
    /// 这次旧写入又赶不上，第一次 `assertEventually` 反而超时。所以改成：先启动、睡够长，确认没有
    /// 遗留事件在路上，清零计数器后再重写，只断言这一次重写触发的回调。
    func testWatcherFiresOnInPlaceRewrite() async throws {
        try write("my-agent.json", #"{"id":"my-agent","name":"My Agent"}"#)
        let fired = Locked(0)
        let watcher = AcpManifestWatcher(directory: directory, debounce: 0.05) { fired.withLock { $0 += 1 } }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        fired.withLock { $0 = 0 }
        try write("my-agent.json", #"{"id":"my-agent","name":"My Agent Renamed"}"#)
        await assertEventually(timeout: 5) { fired.withLock { $0 } >= 1 }
    }

    /// kqueue 的 fd 挂在目录被删前的 vnode 上，目录删了重建（`rm -rf ~/.botbus` 再重装）之后永远不会
    /// 再触发；FSEvents 按路径订阅，靠 `kFSEventStreamEventFlagRootChanged` 重开一条流接住后续事件。
    ///
    /// 删除本身、root changed 与重开流都会各自触发一次回调；这些如果和"清零计数器"前后脚发生，
    /// 会让清零之后立刻又冒出一次，掩盖了后面真正要测的"新流能不能收到新清单"。所以先睡够久等这些
    /// 迟到的回调都落定，再清零、再写新清单，只断言这一次写入触发的回调——这样才是真的测出「重开的
    /// 流还在正常工作」，不是蹭了删除事件本身的回调。
    func testWatcherFiresAfterDirectoryDeletedAndRecreated() async throws {
        let fired = Locked(0)
        let watcher = AcpManifestWatcher(directory: directory, debounce: 0.05) { fired.withLock { $0 += 1 } }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(1000))
        fired.withLock { $0 = 0 }
        try write("my-agent.json", #"{"id":"my-agent","name":"My Agent"}"#)
        await assertEventually(timeout: 5) { fired.withLock { $0 } >= 1 }
    }

    func testWatcherFiresWhenManifestRemoved() async throws {
        try write("my-agent.json", #"{"id":"my-agent","name":"My Agent"}"#)
        let fired = Locked(0)
        let watcher = AcpManifestWatcher(directory: directory, debounce: 0.05) { fired.withLock { $0 += 1 } }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        fired.withLock { $0 = 0 }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("my-agent.json"))
        await assertEventually(timeout: 5) { fired.withLock { $0 } >= 1 }
    }

    func testStoppedWatcherStaysQuiet() async throws {
        let fired = Locked(0)
        let watcher = AcpManifestWatcher(directory: directory, debounce: 0.05) { fired.withLock { $0 += 1 } }
        watcher.start()
        watcher.stop()
        try write("my-agent.json", #"{"id":"my-agent","name":"My Agent"}"#)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(fired.current, 0)
    }

    #if !canImport(CoreServices)
    /// 一口气写好几个清单只回调一次：调用方每次回调都要重新 discover，不该被连着叫。
    /// 只在 inotify 这边断言：FSEvents 自己会把一批事件拆成前后两批送来，那不是去抖该管的。
    func testWatcherDebouncesABurstIntoOneCallback() async throws {
        let fired = Locked(0)
        let watcher = AcpManifestWatcher(directory: directory, debounce: 0.3) { fired.withLock { $0 += 1 } }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        for index in 0..<5 { try write("agent-\(index).json", #"{"id":"agent-\#(index)","name":"A"}"#) }
        await assertEventually(timeout: 5) { fired.withLock { $0 } >= 1 }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(fired.current, 1)
    }

    /// inotify 用不了时的退路：每隔一会儿比一次目录清单与 mtime / 大小 / inode。
    func testPollingWatcherSeesAddRewriteRemoveAndRecreatedDirectory() async throws {
        let fired = Locked(0)
        let watcher = AcpManifestWatcher(directory: directory, debounce: 0.05, pollInterval: 0.1, forcePolling: true) {
            fired.withLock { $0 += 1 }
        }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(fired.current, 0, "启动时已有的东西不算变化")

        try write("my-agent.json", #"{"id":"my-agent","name":"My Agent"}"#)
        await assertEventually(timeout: 3) { fired.withLock { $0 } >= 1 }

        fired.withLock { $0 = 0 }
        try write("my-agent.json", #"{"id":"my-agent","name":"My Agent Renamed"}"#)
        await assertEventually(timeout: 3) { fired.withLock { $0 } >= 1 }

        fired.withLock { $0 = 0 }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("my-agent.json"))
        await assertEventually(timeout: 3) { fired.withLock { $0 } >= 1 }

        try FileManager.default.removeItem(at: directory)
        await assertEventually(timeout: 3) { FileManager.default.fileExists(atPath: self.directory.path) }
        try await Task.sleep(for: .milliseconds(300))
        fired.withLock { $0 = 0 }
        try write("again.json", #"{"id":"again","name":"Again"}"#)
        await assertEventually(timeout: 3) { fired.withLock { $0 } >= 1 }
    }
    #endif
}
