import XCTest
@testable import BotBusConnectors

final class ClaudePathsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 在 `root/<version>/` 下放一个可执行的 `claude.exe`（Windows 认后缀，POSIX 认执行位）。
    private func install(_ version: String) throws {
        let directory = root.appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("claude.exe")
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    private func pick() -> String? {
        ClaudePaths.newestVersionedBinary(in: root.path, executable: "claude.exe")
    }

    func testPicksHighestVersionNumericallyNotLexically() throws {
        try install("2.1.9")
        try install("2.1.284")
        try install("2.0.500")
        XCTAssertEqual(pick().map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }, "2.1.284")
    }

    func testSkipsNonVersionDirectoriesAndVersionsWithoutBinary() throws {
        try install("2.1.100")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2.1.300", isDirectory: true),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("9.9.9-beta", isDirectory: true),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("latest", isDirectory: true),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(pick().map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }, "2.1.100")
    }

    /// 桌面 app 2.1.28x 起版本目录下再隔一层哈希目录；同一版本几个哈希目录时取修改时间最新的那份。
    func testVersionDirectoriesWithAHashLayer() throws {
        func install(_ relative: String, modified: Date) throws {
            let binary = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: modified],
                                                  ofItemAtPath: binary.path)
        }
        try install("2.1.284/4819fdb9b264/claude.exe", modified: Date(timeIntervalSince1970: 3_000))
        try install("2.1.286/aaaa/claude.exe", modified: Date(timeIntervalSince1970: 1_000))
        try install("2.1.286/bbbb/claude.exe", modified: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(pick(), root.appendingPathComponent("2.1.286/bbbb/claude.exe").path)
    }

    func testMissingRootFindsNothing() {
        XCTAssertNil(ClaudePaths.newestVersionedBinary(in: root.appendingPathComponent("absent").path, executable: "claude.exe"))
        XCTAssertNil(pick())
    }

    #if os(macOS)
    /// Mac 的 Claude 桌面 app 把 Claude Code 放在 `<版本>/claude.app/Contents/MacOS/claude`。
    func testMacDesktopCopyInsideItsAppBundle() throws {
        for version in ["2.1.281", "2.1.284"] {
            let binary = root.appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent(ClaudePaths.desktopClaudeCodeExecutable)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let found = ClaudePaths.newestVersionedBinary(in: root.path, executable: ClaudePaths.desktopClaudeCodeExecutable)
        XCTAssertEqual(found, root.appendingPathComponent("2.1.284/claude.app/Contents/MacOS/claude").path)
    }

    /// 现在的布局：`<版本>/<哈希>/claude.app/Contents/MacOS/claude`。
    func testMacDesktopCopyBehindAHashDirectory() throws {
        let binary = root.appendingPathComponent("2.1.286/f2326db61802", isDirectory: true)
            .appendingPathComponent(ClaudePaths.desktopClaudeCodeExecutable)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let found = ClaudePaths.newestVersionedBinary(in: root.path, executable: ClaudePaths.desktopClaudeCodeExecutable)
        XCTAssertEqual(found, binary.path)
        XCTAssertEqual(found.flatMap { ClaudePaths.version(ofBinary: $0) }, [2, 1, 286])
    }
    #endif

    // MARK: - 挑版本最高的那份

    func testPicksTheNewestCandidateAndPrefersEarlierOnTies() {
        let versions: [String: [Int]] = ["cli": [2, 1, 104], "desktop": [2, 1, 286], "same": [2, 1, 286]]
        XCTAssertEqual(ClaudePaths.newest(["cli", "desktop"]) { versions[$0] }, "desktop")
        XCTAssertEqual(ClaudePaths.newest(["desktop", "cli"]) { versions[$0] }, "desktop")
        // 一样高：排在前面的（命令行装的）优先。
        XCTAssertEqual(ClaudePaths.newest(["same", "desktop"]) { versions[$0] }, "same")
    }

    func testCandidatesWithoutAVersionLoseToOnesWithOne() {
        let versions: [String: [Int]] = ["desktop": [2, 1, 1]]
        XCTAssertEqual(ClaudePaths.newest(["broken", "desktop"]) { versions[$0] }, "desktop")
        // 都读不出：按原来的顺序。
        XCTAssertEqual(ClaudePaths.newest(["a", "b"]) { _ in nil }, "a")
        XCTAssertNil(ClaudePaths.newest([]) { _ in nil })
    }

    func testASingleCandidateIsUsedWithoutReadingItsVersion() {
        XCTAssertEqual(ClaudePaths.newest(["only"]) { _ in XCTFail("只有一份时不读版本"); return nil }, "only")
    }

    func testVersionFromTheInstallPath() {
        XCTAssertEqual(ClaudePaths.versionInPath("/Users/me/.local/share/claude/versions/2.1.104"), [2, 1, 104])
        XCTAssertEqual(ClaudePaths.versionInPath(
            "/Users/me/Library/Application Support/Claude/claude-code/2.1.286/f2326db61802/claude.app/Contents/MacOS/claude"),
            [2, 1, 286])
        XCTAssertEqual(ClaudePaths.versionInPath("/opt/homebrew/Caskroom/claude-code/2.1.290/claude"), [2, 1, 290])
        XCTAssertEqual(ClaudePaths.versionInPath(#"C:\Users\me\AppData\Roaming\Claude\claude-code\2.1.286\claude.exe"#),
                       [2, 1, 286])
        XCTAssertNil(ClaudePaths.versionInPath("/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude"))
        // 离文件太远的是用户自己的目录，不算。
        XCTAssertNil(ClaudePaths.versionInPath("/Users/me/1.0.0/a/b/c/d/e/f/claude"))
    }

    func testParsesVersionOutput() {
        XCTAssertEqual(ClaudePaths.parseVersion("2.1.286 (Claude Code)"), [2, 1, 286])
        XCTAssertEqual(ClaudePaths.parseVersion("2.1.9"), [2, 1, 9])
        XCTAssertNil(ClaudePaths.parseVersion("2.1"))
        XCTAssertNil(ClaudePaths.parseVersion("v2.1.3"))
        XCTAssertNil(ClaudePaths.parseVersion("Claude Code 2.1.3"))
    }

    #if !os(Windows)
    /// 路径里认不出版本时跑一次 `--version`。
    func testReadsTheVersionFromTheBinaryWhenThePathHasNone() throws {
        let binary = root.appendingPathComponent("bin/claude")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho '2.1.300 (Claude Code)'\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertEqual(ClaudePaths.version(ofBinary: binary.path), [2, 1, 300])

        let broken = root.appendingPathComponent("bin/broken")
        try "#!/bin/sh\nexit 1\n".write(to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        XCTAssertNil(ClaudePaths.version(ofBinary: broken.path))
    }
    #endif
}
