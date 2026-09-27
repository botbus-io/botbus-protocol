import Darwin
import Foundation
import BotBusConnectorKit

/// 本机一个进程的命令行与环境变量（只收同一用户的进程）。
public struct DshProcessInfo: Hashable, Sendable {
    public var pid: Int32
    public var arguments: [String]
    public var environment: [String: String]

    public init(pid: Int32, arguments: [String], environment: [String: String]) {
        self.pid = pid
        self.arguments = arguments
        self.environment = environment
    }
}

/// 枚举进程与监听端口。测试注入假的；生产用 `SystemDshProcessListing`。
public protocol DshProcessListing: Sendable {
    /// 本用户的全部进程（读不到命令行的跳过）。
    func processes() -> [DshProcessInfo]
    /// 这个进程在回环（或全部）地址上监听的 TCP 端口，升序去重。
    func listeningPorts(pid: Int32) -> [Int]
}

/// 找到的一个 `dsh web`。
public struct DshWebInstance: Hashable, Sendable {
    public var pid: Int32
    public var ports: [Int]

    public var endpoints: [DshWebEndpoint] { ports.map(DshWebEndpoint.init(port:)) }
}

/// 找本机正在跑的 `dsh web`（spec「DshWebLink」）：命令行里有 dsh 入口（`dsh` 可执行文件或 `@deepseek-ai/dsh/lib/bin.js`），
/// 子命令是 `web`（或 `--profile web`）；环境里的 `DSH_HOME` 没设、或与我们用的主目录相同；再读它在回环地址上监听的端口。
///
/// 纯逻辑（`isDshWeb`、`usesHome`）与枚举（`DshProcessListing`）分开，前者单测。多个实例时按 pid 升序给出，调用方取第一个能连上的。
public enum DshWebLocator {
    public static func locate(paths: DshPaths, listing: any DshProcessListing = SystemDshProcessListing()) -> [DshWebInstance] {
        listing.processes()
            .filter { isDshWeb(arguments: $0.arguments) && usesHome(environment: $0.environment, paths: paths) }
            .sorted { $0.pid < $1.pid }
            .compactMap { process in
                let ports = listing.listeningPorts(pid: process.pid)
                return ports.isEmpty ? nil : DshWebInstance(pid: process.pid, ports: ports)
            }
    }

    /// 命令行是不是 `dsh web`。入口之后的参数里：`--profile web` / `--profile=web`，或者第一个不以 `-` 开头的参数是 `web`。
    /// `npm exec @deepseek-ai/dsh web` 这种包名参数不算入口（它是 npm，不监听端口）。
    public static func isDshWeb(arguments: [String]) -> Bool {
        guard let entry = arguments.firstIndex(where: isDshEntry) else { return false }
        let rest = Array(arguments[(entry + 1)...])
        for (index, argument) in rest.enumerated() {
            if argument == "--profile=web" { return true }
            if argument == "--profile", index + 1 < rest.count, rest[index + 1] == "web" { return true }
        }
        var skipNext = false
        for argument in rest {
            if skipNext { skipNext = false; continue }
            if argument == "--profile" { skipNext = true; continue }
            if argument.hasPrefix("-") { continue }
            return argument == "web"
        }
        return false
    }

    static func isDshEntry(_ argument: String) -> Bool {
        if argument.hasSuffix("/@deepseek-ai/dsh/lib/bin.js") { return true }
        guard !argument.hasPrefix("@") else { return false }
        return (argument as NSString).lastPathComponent == "dsh"
    }

    /// 这个进程用的主目录就是我们的：`DSH_HOME` 设了就看它（展开 `~`、规范化之后比），没设就是它自己 `HOME` 下的 `.dsh`
    ///（环境里没有 `HOME` 时按本用户的主目录算）。
    public static func usesHome(environment: [String: String], paths: DshPaths) -> Bool {
        let effective: String
        if let value = environment["DSH_HOME"], !value.isEmpty {
            effective = value
        } else {
            let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            effective = (home as NSString).appendingPathComponent(".dsh")
        }
        return normalized(effective) == normalized(paths.home.path)
    }

    private static func normalized(_ path: String) -> String {
        var text = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return (text as NSString).resolvingSymlinksInPath
    }
}

/// 用 libproc 与 sysctl 枚举：`proc_listallpids` → 同 uid 的 → `KERN_PROCARGS2` 读 argv 与环境变量；
/// 端口用 `PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO` 找处于 LISTEN 的 TCP socket。只读，不需要额外权限（同用户进程）。
public struct SystemDshProcessListing: DshProcessListing {
    public init() {}

    public func processes() -> [DshProcessInfo] {
        let uid = getuid()
        return Self.allPids().compactMap { pid in
            guard pid > 0, Self.owner(of: pid) == uid, let (arguments, environment) = Self.arguments(of: pid) else { return nil }
            return DshProcessInfo(pid: pid, arguments: arguments, environment: environment)
        }
    }

    public func listeningPorts(pid: Int32) -> [Int] {
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 16)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        var ports: Set<Int> = []
        for fd in fds.prefix(Int(filled) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let inet = tcp.tcpsi_ini
            guard Self.isLoopbackOrAny(inet) else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    /// 127.0.0.0/8、::1、0.0.0.0、::（后两者也接受回环连接）。
    static func isLoopbackOrAny(_ inet: in_sockinfo) -> Bool {
        if inet.insi_vflag & UInt8(INI_IPV4) != 0 {
            let address = UInt32(bigEndian: inet.insi_laddr.ina_46.i46a_addr4.s_addr)
            return address == 0 || address >> 24 == 127
        }
        var v6 = inet.insi_laddr.ina_6
        let raw = withUnsafeBytes(of: &v6) { Array($0) }
        let any = raw.allSatisfy { $0 == 0 }
        let loopback = raw.dropLast().allSatisfy { $0 == 0 } && raw.last == 1
        // IPv4 映射地址 ::ffff:127.x.x.x
        let mapped = raw.prefix(10).allSatisfy { $0 == 0 } && raw[10] == 0xff && raw[11] == 0xff && raw[12] == 127
        return any || loopback || mapped
    }

    private static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)))
    }

    private static func owner(of pid: Int32) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    /// `KERN_PROCARGS2`：`argc`（int32）、可执行文件路径、若干 `\0` 填充、`argc` 个参数、然后是环境变量，全是 `\0` 结尾的串。
    static func arguments(of pid: Int32) -> ([String], [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// 拆 `KERN_PROCARGS2` 的字节（单测用）。环境变量里没有 `=` 的项跳过。
    static func parseProcArgs(_ bytes: [UInt8]) -> ([String], [String: String])? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(Int32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard argc > 0 else { return nil }
        var index = 4
        // 可执行文件路径
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        // 填充
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        /// 从 index 读一个 `\0` 结尾的串；读到末尾返回 nil。
        func next() -> String? {
            guard index < bytes.count else { return nil }
            let begin = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let text = String(decoding: bytes[begin..<index], as: UTF8.self)
            index += 1
            return text
        }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = next() else { return nil }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        // 环境变量到第一个空串为止（之后是填充与 apple 专用的键值）。
        while let entry = next(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (arguments, environment)
    }
}
