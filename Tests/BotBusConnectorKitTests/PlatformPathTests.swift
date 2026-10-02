import XCTest
@testable import BotBusConnectorKit

/// 路径形状的平台差异（`PlatformPath`）：POSIX 上必须与原来的写法逐字等价，Windows 上认盘符、UNC、两种分隔符。
final class PlatformPathTests: XCTestCase {
    #if os(Windows)
    func testWindowsAbsolutePaths() {
        XCTAssertTrue(PlatformPath.isAbsolute("C:\\Users\\me"))
        XCTAssertTrue(PlatformPath.isAbsolute("d:/work"))
        XCTAssertTrue(PlatformPath.isAbsolute("\\\\server\\share\\x"))
        XCTAssertFalse(PlatformPath.isAbsolute("C:relative"))
        XCTAssertFalse(PlatformPath.isAbsolute("relative\\x"))
        XCTAssertFalse(PlatformPath.isAbsolute("/c/Users/me"), "Git Bash 的写法不是 Win32 的绝对路径")
    }

    func testWindowsContainmentIgnoresCaseAndSeparators() {
        XCTAssertTrue(PlatformPath.isInside("C:\\Proj\\a.png", root: "c:\\proj"))
        XCTAssertTrue(PlatformPath.isInside("C:/Proj/sub/a.png", root: "C:\\Proj\\"))
        XCTAssertFalse(PlatformPath.isInside("C:\\Proj2\\a.png", root: "C:\\Proj"))
        XCTAssertFalse(PlatformPath.isInside("C:\\Proj", root: "C:\\Proj"))
        XCTAssertEqual(PlatformPath.relativePath(of: "C:\\Proj\\out\\a.png", under: "C:\\proj").map(String.init), "out\\a.png")
        XCTAssertTrue(PlatformPath.same("C:/Users/Me/", "c:\\users\\me"))
        XCTAssertTrue(PlatformPath.isRoot("C:\\"))
        XCTAssertTrue(PlatformPath.isRoot("C:"))
        XCTAssertFalse(PlatformPath.isRoot("C:\\Users"))
        XCTAssertEqual(PlatformPath.join("C:\\Proj", "out/a.png"), "C:\\Proj\\out\\a.png")
    }

    func testWindowsCanonicalPathIsOneSpellingPerDirectory() {
        XCTAssertEqual(PlatformPath.canonical("C:/Users/me/proj"), "C:\\Users\\me\\proj")
        XCTAssertEqual(PlatformPath.canonical("c:\\Users\\me\\proj\\"), "C:\\Users\\me\\proj")
        XCTAssertEqual(PlatformPath.canonical("C:\\"), "C:\\")
        XCTAssertEqual(PlatformPath.canonical("//server/share/x"), "\\\\server\\share\\x")
        // 不是 Windows 绝对路径的不动（空串、相对路径、测试里的 POSIX 写法）。
        XCTAssertEqual(PlatformPath.canonical(""), "")
        XCTAssertEqual(PlatformPath.canonical("relative/x"), "relative/x")
        XCTAssertEqual(PlatformPath.canonical("/Users/me"), "/Users/me")
    }

    func testWindowsSearchPath() {
        var environment = ["Path": "C:\\a;C:\\b", "HOME": "x"]
        XCTAssertEqual(PlatformPath.pathKey(in: environment), "Path")
        XCTAssertEqual(PlatformPath.splitSearchPath(PlatformPath.searchPath(in: environment)!), ["C:\\a", "C:\\b"])
        environment["PATH"] = "C:\\dup"
        PlatformPath.setSearchPath("C:\\new", in: &environment)
        XCTAssertEqual(environment.keys.filter { $0.uppercased() == "PATH" }.count, 1, "不能给子进程留下两份 PATH")
        XCTAssertEqual(PlatformPath.executableFileNames("claude"), ["claude.exe", "claude.cmd", "claude.bat", "claude"])
        XCTAssertEqual(PlatformPath.executableFileNames("node.exe"), ["node.exe"])
    }
    #else
    func testPOSIXMatchesTheOriginalExpressions() {
        for path in ["/", "/Users/me", "relative", "~/x", ""] {
            XCTAssertEqual(PlatformPath.isAbsolute(path), path.hasPrefix("/"), path)
        }
        XCTAssertTrue(PlatformPath.isInside("/proj/a.png", root: "/proj"))
        XCTAssertFalse(PlatformPath.isInside("/proj2/a.png", root: "/proj"))
        XCTAssertFalse(PlatformPath.isInside("/proj", root: "/proj"))
        XCTAssertFalse(PlatformPath.same("/Proj", "/proj"), "POSIX 区分大小写")
        XCTAssertEqual(PlatformPath.relativePath(of: "/proj/out/a.png", under: "/proj").map(String.init), "out/a.png")
        XCTAssertEqual(PlatformPath.join("/proj", "out/a.png"), "/proj/out/a.png")
        XCTAssertEqual(PlatformPath.normalized("/a/b/"), "/a/b")
        XCTAssertEqual(PlatformPath.normalized("/"), "/")
        XCTAssertEqual(PlatformPath.pathKey(in: ["Path": "x"]), "PATH")
        XCTAssertEqual(PlatformPath.splitSearchPath("/a:/b::"), ["/a", "/b"])
        XCTAssertEqual(PlatformPath.executableFileNames("claude"), ["claude"])
        for path in ["/Users/me/proj/", "/", "", "relative"] {
            XCTAssertEqual(PlatformPath.canonical(path), path, "POSIX 上原样返回")
        }
    }
    #endif
}
