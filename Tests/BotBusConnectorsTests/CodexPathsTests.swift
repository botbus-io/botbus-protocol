import XCTest
@testable import BotBusConnectors

final class CodexPathsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 在 `root/<hash>/` 下放一个可执行文件（Windows 认后缀，POSIX 认执行位），修改时间设成 `modified`。
    private func install(_ hash: String, _ executable: String = "codex.exe", modified: Date) throws {
        let directory = root.appendingPathComponent(hash, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent(executable)
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: modified], ofItemAtPath: binary.path)
    }

    private func pick() -> String? {
        CodexPaths.newestBinary(inSubdirectoriesOf: root.path, executable: "codex.exe")
    }

    func testPicksMostRecentlyModifiedHashDirectory() throws {
        try install("0eee8efdd1afa6e8", modified: Date(timeIntervalSince1970: 2_000_000_000))
        try install("ffff000011112222", modified: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(pick().map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }, "0eee8efdd1afa6e8")
    }

    func testSkipsDirectoriesWithoutTheExecutable() throws {
        try install("0eee8efdd1afa6e8", modified: Date(timeIntervalSince1970: 1_900_000_000))
        try install("a1f6938e60a1b3cc", "rg.exe", modified: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(pick().map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }, "0eee8efdd1afa6e8")
    }

    func testMissingRootFindsNothing() {
        XCTAssertNil(CodexPaths.newestBinary(inSubdirectoriesOf: root.appendingPathComponent("absent").path, executable: "codex.exe"))
        XCTAssertNil(pick())
    }

    #if !os(Windows)
    /// 在 `root` 下的相对路径放一个可执行文件，返回绝对路径。
    @discardableResult
    private func file(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// npm 全局装的 `bin/codex` → `@openai/codex/bin/codex.js`：用平台包里的原生程序，不用 node 脚本。
    func testNpmInstallResolvesToThePlatformPackagesNativeBinary() throws {
        let (platform, triple) = try XCTUnwrap(CodexPaths.nativePlatforms.first)
        let script = try file("lib/node_modules/@openai/codex/bin/codex.js")
        let native = try file("lib/node_modules/@openai/codex/node_modules/@openai/codex-\(platform)/vendor/\(triple)/codex/codex")
        let link = root.appendingPathComponent("bin/codex").path
        try FileManager.default.createDirectory(atPath: root.appendingPathComponent("bin").path, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: script)
        XCTAssertEqual(CodexPaths.detectInstalledCLI(locate: { $0 == "codex" ? link : nil }).map(resolved), resolved(native))
    }

    func testHoistedPlatformPackageAndOldVendorLayout() throws {
        let (platform, triple) = try XCTUnwrap(CodexPaths.nativePlatforms.first)
        let package = root.appendingPathComponent("lib/node_modules/@openai/codex").path
        XCTAssertNil(CodexPaths.npmNativeBinary(packageDirectory: package))
        let old = try file("lib/node_modules/@openai/codex/vendor/\(triple)/codex/codex")
        XCTAssertEqual(CodexPaths.npmNativeBinary(packageDirectory: package), old)
        let hoisted = try file("lib/node_modules/@openai/codex-\(platform)/vendor/\(triple)/codex/codex")
        XCTAssertEqual(CodexPaths.npmNativeBinary(packageDirectory: package), hoisted, "平台包优先于旧的 vendor 目录")
    }

    /// 没找到原生程序时退回脚本本身；Homebrew 这类原生程序原样返回；哪都没有就是 nil。
    func testFallsBackToTheScriptOrTheBinaryAsFound() throws {
        let script = try file("lib/node_modules/@openai/codex/bin/codex.js")
        XCTAssertEqual(CodexPaths.detectInstalledCLI(locate: { _ in script }), script)
        let brew = try file("homebrew/bin/codex")
        XCTAssertEqual(CodexPaths.detectInstalledCLI(locate: { _ in brew }), brew)
        XCTAssertNil(CodexPaths.detectInstalledCLI(locate: { _ in nil }))
    }

    private func resolved(_ path: String) -> String { (path as NSString).resolvingSymlinksInPath }
    #endif
}
