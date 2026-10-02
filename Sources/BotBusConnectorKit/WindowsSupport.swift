#if os(Windows)
import Foundation
import WinSDK

/// Windows 上几处接缝共用的 Win32 小工具：宽字符串、错误文本、Winsock 初始化、只给本人的文件与目录（DACL 代替 0600 / 0700）、
/// 原子替换、解析真实路径、进程存活与整棵进程树的结束。
///
/// 「只给本人」的 DACL：受保护（不继承父目录的 ACE），只有当前用户与 SYSTEM 完全控制。
/// 和 Linux 的 0700 / 0600 同一个意思：同机别的用户（包括别的管理员账号在不提权时）打不开。
public enum Win32 {
    // MARK: - 字符串与错误

    public static func withWide<T>(_ string: String, _ body: (UnsafePointer<WCHAR>) throws -> T) rethrows -> T {
        try string.withCString(encodedAs: UTF16.self) { try body($0) }
    }

    public static func string(fromWide buffer: UnsafePointer<WCHAR>) -> String {
        String(decodingCString: buffer, as: UTF16.self)
    }

    /// `GetLastError()` / `WSAGetLastError()` 的系统说明文字，拿不到时只给编号。
    public static func errorMessage(_ code: DWORD) -> String {
        var buffer: UnsafeMutablePointer<WCHAR>?
        let flags = DWORD(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS)
        let length = withUnsafeMutablePointer(to: &buffer) { pointer in
            pointer.withMemoryRebound(to: WCHAR.self, capacity: 1) {
                FormatMessageW(flags, nil, code, 0, $0, 0, nil)
            }
        }
        defer { if let buffer { LocalFree(buffer) } }
        guard length > 0, let buffer else { return "Windows 错误 \(code)" }
        let text = String(decoding: UnsafeBufferPointer(start: buffer, count: Int(length)), as: UTF16.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "（\(code)）"
    }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let call: String
        public let code: DWORD

        public init(_ call: String, code: DWORD = GetLastError()) {
            self.call = call
            self.code = code
        }

        public var description: String { "\(call)：\(Win32.errorMessage(code))" }
    }

    // MARK: - Winsock

    private static let winsockStarted: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()

    /// 进程里第一次用 socket 之前调一次；重复调用无害。
    public static func startWinsock() {
        _ = winsockStarted
    }

    // MARK: - 当前用户

    /// 当前进程用户的 SID 字符串（`S-1-5-21-…`）。管理通道的管道名与 DACL 都按它。
    public static let currentUserSID: String? = {
        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token), let token else { return nil }
        defer { CloseHandle(token) }
        return sidString(ofToken: token)
    }()

    static func sidString(ofToken token: HANDLE) -> String? {
        var length: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &length)
        guard length > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(length), alignment: 16)
        defer { buffer.deallocate() }
        guard GetTokenInformation(token, TokenUser, buffer, length, &length) else { return nil }
        let user = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee
        var text: LPWSTR?
        guard ConvertSidToStringSidW(user.User.Sid, &text), let text else { return nil }
        defer { LocalFree(text) }
        return string(fromWide: text)
    }

    /// 某个进程的用户 SID；打不开（进程已退出、权限不够）返回 nil。
    public static func userSID(ofProcess pid: DWORD) -> String? {
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
        defer { CloseHandle(process) }
        var token: HANDLE?
        guard OpenProcessToken(process, DWORD(TOKEN_QUERY), &token), let token else { return nil }
        defer { CloseHandle(token) }
        return sidString(ofToken: token)
    }

    /// 只给当前用户（与 SYSTEM）完全控制、不继承上级 ACE 的安全描述符（SDDL）。目录的 ACE 让子项继承。
    public static func privateSDDL(directory: Bool) -> String? {
        guard let sid = currentUserSID else { return nil }
        let inherit = directory ? "OICI" : ""
        return "D:P(A;\(inherit);FA;;;SY)(A;\(inherit);FA;;;\(sid))"
    }

    /// 用 SDDL 造一份 `SECURITY_ATTRIBUTES` 交给 `body`（CreateFileW / CreateDirectoryW / CreateNamedPipeW）。
    public static func withSecurityAttributes<T>(sddl: String, _ body: (UnsafeMutablePointer<SECURITY_ATTRIBUTES>) throws -> T) throws -> T {
        var descriptor: PSECURITY_DESCRIPTOR?
        let converted = withWide(sddl) {
            ConvertStringSecurityDescriptorToSecurityDescriptorW($0, DWORD(SDDL_REVISION_1), &descriptor, nil)
        }
        guard converted, let descriptor else { throw Failure("ConvertStringSecurityDescriptorToSecurityDescriptorW") }
        defer { LocalFree(descriptor) }
        var attributes = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                                             lpSecurityDescriptor: descriptor, bInheritHandle: false)
        return try body(&attributes)
    }

    /// 把已有文件或目录的 DACL 换成只给本人（`chmod 0600 / 0700` 的对应物）。
    public static func restrictToCurrentUser(path: String, directory: Bool) throws {
        guard let sddl = privateSDDL(directory: directory) else { throw Failure("GetTokenInformation") }
        var descriptor: PSECURITY_DESCRIPTOR?
        let converted = withWide(sddl) {
            ConvertStringSecurityDescriptorToSecurityDescriptorW($0, DWORD(SDDL_REVISION_1), &descriptor, nil)
        }
        guard converted, let descriptor else { throw Failure("ConvertStringSecurityDescriptorToSecurityDescriptorW") }
        defer { LocalFree(descriptor) }
        var present: WindowsBool = false
        var defaulted: WindowsBool = false
        var dacl: PACL?
        guard GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted) else { throw Failure("GetSecurityDescriptorDacl") }
        let information = SECURITY_INFORMATION(DACL_SECURITY_INFORMATION) | SECURITY_INFORMATION(PROTECTED_DACL_SECURITY_INFORMATION)
        let status = withWide(path) { wide in
            SetNamedSecurityInfoW(UnsafeMutablePointer(mutating: wide), SE_FILE_OBJECT, information, nil, nil, dacl, nil)
        }
        guard status == ERROR_SUCCESS else { throw Failure("SetNamedSecurityInfoW", code: DWORD(status)) }
    }

    /// 建目录（含上级）并把它收紧成只给本人。已存在的也收紧。
    public static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try restrictToCurrentUser(path: url.path, directory: true)
    }

    /// 原子地写一个只给本人的文件：同目录下 `CREATE_NEW` 建临时文件（建出来那一刻就带着私有 DACL）、写完 flush，
    /// 再 `MoveFileExW` 覆盖过去（ucrt 的 `rename` 目标存在时会失败）。
    public static func writePrivateFile(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let sddl = privateSDDL(directory: false) else { throw Failure("GetTokenInformation") }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).tmp")
        let handle: HANDLE = try withSecurityAttributes(sddl: sddl) { attributes in
            let handle = withWide(temporary.path) {
                CreateFileW($0, DWORD(GENERIC_WRITE), 0, attributes, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else { throw Failure("CreateFileW") }
            return handle
        }
        var failure: Failure?
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                var written: DWORD = 0
                let chunk = DWORD(min(raw.count - offset, 1 << 30))
                guard WriteFile(handle, raw.baseAddress! + offset, chunk, &written, nil), written > 0 else {
                    failure = Failure("WriteFile")
                    return
                }
                offset += Int(written)
            }
        }
        if failure == nil, !FlushFileBuffers(handle) { failure = Failure("FlushFileBuffers") }
        CloseHandle(handle)
        if failure == nil {
            do { try replaceFile(at: url, with: temporary) } catch { failure = error as? Failure }
        }
        if let failure {
            _ = withWide(temporary.path) { DeleteFileW($0) }
            throw failure
        }
    }

    /// `source` 挪到 `destination`，目标在就覆盖（同一卷上是原子的）。
    public static func replaceFile(at destination: URL, with source: URL) throws {
        let moved = withWide(source.path) { from in
            withWide(destination.path) { to in
                MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        guard moved else { throw Failure("MoveFileExW") }
    }

    // MARK: - 路径

    /// 解析掉符号链接与 junction 后的真实路径（`realpath` 的对应物）；打不开返回 nil。去掉 `\\?\` 前缀。
    public static func finalPath(_ path: String) -> String? {
        let handle = withWide(path) {
            CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(handle) }
        return finalPath(ofHandle: handle)
    }

    public static func finalPath(ofHandle handle: HANDLE) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 1024)
        var length = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), DWORD(FILE_NAME_NORMALIZED))
        if length >= DWORD(buffer.count) {
            buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
            length = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), DWORD(FILE_NAME_NORMALIZED))
        }
        guard length > 0, length < DWORD(buffer.count) else { return nil }
        let text = String(decoding: buffer[0..<Int(length)], as: UTF16.self)
        if text.hasPrefix("\\\\?\\UNC\\") { return "\\\\" + text.dropFirst(8) }
        if text.hasPrefix("\\\\?\\") { return String(text.dropFirst(4)) }
        return text
    }

    /// 电脑名（设置 → 系统 → 系统信息里的「设备名称」）：DNS 主机名保留大小写，NetBIOS 名是全大写的。
    public static func computerName() -> String? {
        var buffer = [WCHAR](repeating: 0, count: 256)
        var size = DWORD(buffer.count)
        guard GetComputerNameExW(ComputerNameDnsHostname, &buffer, &size), size > 0 else { return nil }
        return String(decoding: buffer[0..<Int(size)], as: UTF16.self)
    }

    // MARK: - 进程

    /// 进程还在不在。打不开但是因为没权限（别的用户的进程）也算在。
    public static func processExists(_ pid: DWORD) -> Bool {
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION) | DWORD(SYNCHRONIZE), false, pid) else {
            return GetLastError() == DWORD(ERROR_ACCESS_DENIED)
        }
        defer { CloseHandle(process) }
        return WaitForSingleObject(process, 0) == DWORD(WAIT_TIMEOUT)
    }

    /// 结束 `pid` 与它的全部子孙进程（先子后父）。Windows 没有进程组信号：`kill(-pgid, …)` / `kill(pid, SIGINT)`
    /// 的对应物就是整棵树结束掉——npm 装的 `claude.cmd` 是 cmd → node 两层，只结束 cmd 会留下 node 继续跑。
    public static func terminateProcessTree(_ pid: DWORD, exitCode: UINT = 1) {
        var children: [DWORD: [DWORD]] = [:]
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        if let snapshot, snapshot != INVALID_HANDLE_VALUE {
            var entry = PROCESSENTRY32W()
            entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
            if Process32FirstW(snapshot, &entry) {
                repeat {
                    children[entry.th32ParentProcessID, default: []].append(entry.th32ProcessID)
                } while Process32NextW(snapshot, &entry)
            }
            CloseHandle(snapshot)
        }
        var visited = Set<DWORD>()
        func terminate(_ pid: DWORD) {
            guard visited.insert(pid).inserted else { return }
            for child in children[pid] ?? [] where child != pid { terminate(child) }
            if let process = OpenProcess(DWORD(PROCESS_TERMINATE), false, pid) {
                TerminateProcess(process, exitCode)
                CloseHandle(process)
            }
        }
        terminate(pid)
    }
}
#endif
