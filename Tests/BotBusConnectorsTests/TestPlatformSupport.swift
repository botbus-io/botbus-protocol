import Foundation
import XCTest

extension XCTestCase {
    /// 建符号链接。Windows 上没开开发者模式（也没以管理员运行）时建不了（`ERROR_PRIVILEGE_NOT_HELD`）：
    /// 这条用例跳过而不是失败，其余平台出错照常抛。
    func makeSymbolicLink(at url: URL, withDestinationURL destination: URL) throws {
        do {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        } catch {
            #if os(Windows)
            throw XCTSkip("这台 Windows 上建不了符号链接（要开开发者模式）：\(error)")
            #else
            throw error
            #endif
        }
    }
}

/// 只要"存在且可执行"、不会真的被运行的假 CLI 的文件名：Windows 只把 `.exe` 等后缀当可执行文件。
let fakeCLIName: String = {
    #if os(Windows)
    return "botbus.exe"
    #else
    return "botbus"
    #endif
}()

/// 这条用例要真的运行一个 `#!/bin/sh` 写的假 agent：Windows 跑不了 shell 脚本，跳过——同一段逻辑在 macOS / Linux 上覆盖，
/// Windows 上的子进程收发由端到端测试（`scripts/windows/e2e.ps1`）兜住。
func skipPOSIXScriptOnWindows() throws {
    #if os(Windows)
    throw XCTSkip("要运行 POSIX shell 写的假 agent，Windows 上跳过")
    #endif
}

/// 本机一定有、一定可执行的一个程序（只用来通过"存在且可执行"的检查，或 `-c exit 0` 这类最简单的调用）。
let anyExecutablePath: String = {
    #if os(Windows)
    return (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\cmd.exe"
    #else
    return "/bin/sh"
    #endif
}()

/// `anyExecutablePath` 写进 JSON 字符串里的样子（Windows 路径的反斜杠要转义）。
let anyExecutableJSON: String = anyExecutablePath.replacingOccurrences(of: "\\", with: "\\\\")

/// 一个"绝对路径"样子的图片路径（不必存在），与它写进 JSON 字符串里的样子。
let sampleImagePath: String = {
    #if os(Windows)
    return "C:\\tmp\\x.png"
    #else
    return "/tmp/x.png"
    #endif
}()
let sampleImageJSON: String = sampleImagePath.replacingOccurrences(of: "\\", with: "\\\\")
