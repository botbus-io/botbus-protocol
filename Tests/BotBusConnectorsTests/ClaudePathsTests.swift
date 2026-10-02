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
    #endif
}
