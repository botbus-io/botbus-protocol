import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class DshPathsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 在假 npx 缓存里放一份包；`withBin: false` 模拟装了一半的缓存。
    private func addNpxPackage(hash: String, version: String, name: String = "@deepseek-ai/dsh",
                               withBin: Bool = true) throws {
        let directory = root.appendingPathComponent("npx/\(hash)/node_modules/@deepseek-ai/dsh", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let manifest = try JSONSerialization.data(withJSONObject: ["name": name, "version": version])
        try manifest.write(to: directory.appendingPathComponent("package.json"))
        if withBin { try Data("#!/usr/bin/env node\n".utf8).write(to: directory.appendingPathComponent("lib/bin.js")) }
    }

    private func executable(_ relative: String) throws -> String {
        try skipPOSIXScriptOnWindows()
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testDirectoriesUnderInjectedHome() {
        let paths = DshPaths(home: root)
        XCTAssertEqual(paths.sessionsDirectory.path, root.appendingPathComponent("sessions").path)
        XCTAssertEqual(paths.projectionCacheFile(sessionId: "session-1").path,
                       root.appendingPathComponent("storages/session_projcache/sessions/session-1.json").path)
        XCTAssertEqual(paths.credentialsFile.lastPathComponent, ".credentials.yaml")
        XCTAssertEqual(paths.environment, ["DSH_HOME": root.path])
        XCTAssertFalse(paths.isInstalled(nil))
    }

    func testSessionsDirectoryAloneCountsAsInstalled() throws {
        let paths = DshPaths(home: root)
        try FileManager.default.createDirectory(at: paths.sessionsDirectory, withIntermediateDirectories: true)
        XCTAssertTrue(paths.isInstalled(nil))
    }

    func testVersionOrderingFollowsSemver() throws {
        let ordered = ["0.1.4", "0.1.5-alpha", "0.1.5-rc.2", "0.1.5-rc.3", "0.1.5-rc.10", "0.1.5-rc.10.1", "0.1.5-rc.x",
                       "0.1.5", "0.2.0", "1.0.0"].map { DshVersion($0)! }
        XCTAssertEqual(ordered, ordered.sorted())
        for (lower, higher) in zip(ordered, ordered.dropFirst()) { XCTAssertLessThan(lower, higher) }
        XCTAssertEqual(DshVersion("0.1.5-rc.3+build.7"), DshVersion("0.1.5-rc.3"))
        XCTAssertEqual(DshVersion("0.1.5-rc.3")?.description, "0.1.5-rc.3")
        XCTAssertNil(DshVersion("0.1"))
        XCTAssertNil(DshVersion("0.1.x"))
        XCTAssertNil(DshVersion("0.1.5-"))
        XCTAssertNil(DshVersion("0.1.5-rc..1"))
    }

    func testNewestNpxPackageWins() throws {
        try addNpxPackage(hash: "aaa", version: "0.1.4")
        try addNpxPackage(hash: "bbb", version: "0.1.5-rc.10")
        try addNpxPackage(hash: "ccc", version: "0.1.5-rc.3")
        try addNpxPackage(hash: "ddd", version: "0.9.0", withBin: false)
        try addNpxPackage(hash: "eee", version: "9.9.9", name: "@someone/else")
        try addNpxPackage(hash: "fff", version: "not-a-version")
        let package = DshPaths.newestNpxPackage(npxRoot: root.appendingPathComponent("npx"))
        XCTAssertEqual(package?.version.description, "0.1.5-rc.10")
        XCTAssertEqual(package?.directory.path.contains("/bbb/"), true)
        XCTAssertNil(DshPaths.newestNpxPackage(npxRoot: root.appendingPathComponent("nothing")))
    }

    func testSelectNodeSkipsOldAndMissing() throws {
        let old = try executable("old/node")
        let fresh = try executable("fresh/node")
        let versions = [old: DshVersion("20.12.0")!, fresh: DshVersion("24.1.0")!]
        let asked = Locked<[String]>([])
        let picked = DshPaths.selectNode(from: [root.appendingPathComponent("missing/node").path, old, fresh, fresh],
                                         version: { path in asked.withLock { $0.append(path) }; return versions[path] })
        XCTAssertEqual(picked, fresh)
        XCTAssertEqual(asked.current, [old, fresh], "不存在的不问，同一个文件只问一次")
        XCTAssertNil(DshPaths.selectNode(from: [old], version: { versions[$0] }))
    }

    func testNpxInstallationRunsBinJsWithNode() throws {
        try addNpxPackage(hash: "bbb", version: "0.1.5-rc.3")
        let node = try executable("bin/node")
        let installation = DshPaths.detectInstallation(locate: { _ in nil }, npxRoot: root.appendingPathComponent("npx"),
                                                       desktopBundles: [], nodeCandidates: [node], nodeVersion: { _ in DshVersion("24.0.0") })
        XCTAssertEqual(installation?.kind, .npxCache)
        XCTAssertEqual(installation?.executable, node)
        XCTAssertEqual(installation?.node, node)
        XCTAssertEqual(installation?.version, "0.1.5-rc.3")
        let script = try XCTUnwrap(installation?.leadingArguments.first)
        XCTAssertTrue(script.hasSuffix("/bbb/node_modules/@deepseek-ai/dsh/lib/bin.js"), script)
        XCTAssertEqual(installation?.acpArguments, [script, "--profile", "acp"])

        let spec = try XCTUnwrap(installation?.acpSpec(paths: DshPaths(home: root)))
        XCTAssertEqual(spec.id, "dsh")
        XCTAssertEqual(spec.executable, node)
        XCTAssertEqual(spec.arguments, [script, "--profile", "acp"])
        XCTAssertEqual(spec.environment, ["DSH_HOME": root.path])
    }

    func testNpxCacheWithoutUsableNodeIsNotAnInstallation() throws {
        try addNpxPackage(hash: "bbb", version: "0.1.5-rc.3")
        let node = try executable("bin/node")
        XCTAssertNil(DshPaths.detectInstallation(locate: { _ in nil }, npxRoot: root.appendingPathComponent("npx"),
                                                 desktopBundles: [], nodeCandidates: [node], nodeVersion: { _ in DshVersion("18.0.0") }))
    }

    func testDesktopBundledCliWinsOverOlderNpxAndPath() throws {
        let bundle = root.appendingPathComponent("DeepSeek Harness.app")
        let script = try executable("DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh")
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.deepseek.dsh",
                                                                        "CFBundleShortVersionString": "0.2.0-rc.2"],
                                                        format: .xml, options: 0)
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try addNpxPackage(hash: "old", version: "0.1.5-rc.3")
        let old = try executable("old/dsh")
        let node = try executable("bin/node")
        let installation = DshPaths.detectInstallation(locate: { _ in old }, npxRoot: root.appendingPathComponent("npx"),
                                                       desktopBundles: [bundle], nodeCandidates: [node],
                                                       nodeVersion: { _ in DshVersion("24.0.0") })
        XCTAssertEqual(installation?.executable, script)
        XCTAssertEqual(installation?.version, "0.2.0-rc.2")
        XCTAssertEqual(installation?.acpArguments, ["--profile", "acp"])
    }

    func testMissingDesktopCliFallsBackToNpx() throws {
        try addNpxPackage(hash: "only", version: "0.1.5-rc.3")
        let node = try executable("bin/node")
        let installation = DshPaths.detectInstallation(locate: { _ in nil }, npxRoot: root.appendingPathComponent("npx"),
                                                       desktopBundles: [root.appendingPathComponent("Missing.app")],
                                                       nodeCandidates: [node], nodeVersion: { _ in DshVersion("24.0.0") })
        XCTAssertEqual(installation?.kind, .npxCache)
    }

    func testBinaryOnPathWinsAndPrefersNodeBesideIt() throws {
        try addNpxPackage(hash: "bbb", version: "0.1.5-rc.3")
        let dsh = try executable("global/bin/dsh")
        let beside = try executable("global/bin/node")
        let other = try executable("other/node")
        let installation = DshPaths.detectInstallation(locate: { $0 == "dsh" ? dsh : nil },
                                                       npxRoot: root.appendingPathComponent("npx"),
                                                       desktopBundles: [], nodeCandidates: [other], nodeVersion: { _ in DshVersion("23.8.0") })
        XCTAssertEqual(installation?.kind, .binary)
        XCTAssertEqual(installation?.executable, dsh)
        XCTAssertEqual(installation?.acpArguments, ["--profile", "acp"])
        XCTAssertEqual(installation?.node, beside)
        XCTAssertNil(installation?.version)
    }

    /// 本机真实 node 的版本探测：没有 node 就跳过。
    func testProbeNodeVersionOnThisMachine() throws {
        guard let node = DshPaths.defaultNodeCandidates().first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("本机没有 node")
        }
        XCTAssertNotNil(DshPaths.probeNodeVersion(node))
    }
}
