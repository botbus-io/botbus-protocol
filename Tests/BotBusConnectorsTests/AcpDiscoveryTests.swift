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
        try write("my-agent.json", #"{"id":"my-agent","name":"My Agent","command":"/bin/sh","args":["-c","exit 0"],"env":{"A":"1"}}"#)
        let result = AcpDiscovery.discover(manifestDirectory: directory, catalog: [], locate: locate)
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.agents, [AcpAgentSpec(id: "my-agent", name: "My Agent", executable: "/bin/sh",
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
        let packageBinary = directory.appendingPathComponent("lib/node_modules/@google/gemini-cli/bin/gemini")
        try FileManager.default.createDirectory(at: packageBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: packageBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packageBinary.path)

        // 装好后 PATH 上真正找到的那个 bin 其实是个软链接，指回 node_modules 里的真实文件。
        let symlinkDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        let symlink = symlinkDirectory.appendingPathComponent("gemini")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: packageBinary)

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

    func testManifestWinsOverRegistry() throws {
        try write("gemini.json", #"{"id":"gemini","name":"我的 Gemini","command":"/bin/sh"}"#)
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
}
