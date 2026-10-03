import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

/// 进程相关的平台差异：本进程 / 父进程的 PID、某个 PID 还在不在、让子进程停下（中断）。
///
/// macOS / Linux 上就是原来的 `getpid()`、`getppid()`、`kill(pid, 0)`、`kill(pid, SIGINT)`。
/// Windows 没有信号：「中断」只能结束整棵进程树（npm 装的命令是 cmd → node 两层，只结束外层会留下里层继续跑），
/// 连接器照常从进程退出收尾。
public enum PlatformProcess {
    public static var currentPID: Int32 {
        #if os(Windows)
        return Int32(bitPattern: GetCurrentProcessId())
        #else
        return getpid()
        #endif
    }

    public static var parentPID: Int32 {
        #if os(Windows)
        let me = GetCurrentProcessId()
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard let snapshot, snapshot != INVALID_HANDLE_VALUE else { return 0 }
        defer { CloseHandle(snapshot) }
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        guard Process32FirstW(snapshot, &entry) else { return 0 }
        repeat {
            if entry.th32ProcessID == me { return Int32(bitPattern: entry.th32ParentProcessID) }
        } while Process32NextW(snapshot, &entry)
        return 0
        #else
        return getppid()
        #endif
    }

    /// 本用户的这个进程还在（POSIX 就是 `kill(pid, 0) == 0`）。
    public static func exists(_ pid: Int32) -> Bool {
        #if os(Windows)
        guard pid > 0 else { return false }
        return Win32.processExists(DWORD(bitPattern: pid))
        #else
        return kill(pid, 0) == 0
        #endif
    }

    /// 让子进程停下：POSIX 发 SIGINT（agent 自己收尾、写完 transcript 再退），Windows 结束它和它的子孙。
    public static func interrupt(_ pid: Int32) {
        guard pid > 0 else { return }
        #if os(Windows)
        Win32.terminateProcessTree(DWORD(bitPattern: pid), exitCode: 0xC000_013A) // STATUS_CONTROL_C_EXIT
        #else
        kill(pid, SIGINT)
        #endif
    }
}
