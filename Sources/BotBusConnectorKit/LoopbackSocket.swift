#if !canImport(Network) && !os(Windows)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// 没有 Network.framework 的平台上，`LocalHookServer` 用到的全部 TCP 系统调用都在这里。
///
/// 目前只有 Glibc（Linux）。Windows 以后在这里补一份 Winsock 的实现即可（`SOCKET` 句柄、`WSAPoll`、
/// `closesocket`、用 `SO_EXCLUSIVEADDRUSE` 代替 `SO_REUSEADDR`、`ioctlsocket(FIONBIO)` 设非阻塞），
/// `LocalHookServer+POSIX.swift` 只认这里的几个函数，不必跟着改。
enum LoopbackSocket {
    typealias Descriptor = Int32

    /// `SOCK_STREAM | SOCK_CLOEXEC`：Glibc 把这两个导成枚举，Musl 上就是 Int32。
    #if canImport(Glibc)
    private static let streamType = Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
    #else
    private static let streamType = SOCK_STREAM | SOCK_CLOEXEC
    #endif

    struct Failure: Error, CustomStringConvertible, Sendable {
        let call: String
        let code: Int32

        var description: String { "\(call): \(String(cString: strerror(code))) (errno \(code))" }
    }

    /// 绑 `127.0.0.1:port`（0 = 让系统挑）并开始监听，返回监听 fd 与实际端口。fd 非阻塞、`FD_CLOEXEC`。
    ///
    /// 设 `SO_REUSEADDR`：Linux 上它只放过 TIME_WAIT 里的旧连接（每条连接都由我们先关，TIME_WAIT 落在这边），
    /// 不允许两个监听共用同一个端口——和 macOS 上 `allowLocalEndpointReuse = false` 的效果一致。
    /// 不设的话，Agent 重启后 `requestedPort` 会因为上一轮的 TIME_WAIT 绑不上。
    static func makeListener(port: UInt16, backlog: Int32) throws -> (descriptor: Descriptor, port: UInt16) {
        let descriptor = socket(AF_INET, streamType, 0)
        guard descriptor >= 0 else { throw Failure(call: "socket", code: errno) }
        do {
            var on: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw Failure(call: "setsockopt(SO_REUSEADDR)", code: errno)
            }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian // 127.0.0.1
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw Failure(call: "bind", code: errno) }
            guard listen(descriptor, backlog) == 0 else { throw Failure(call: "listen", code: errno) }

            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            guard named == 0 else { throw Failure(call: "getsockname", code: errno) }
            try setNonBlocking(descriptor)
            return (descriptor, UInt16(bigEndian: actual.sin_port))
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    enum Accepted {
        /// 新连接：fd 已经非阻塞、`FD_CLOEXEC`；`peer` 是对端地址的文本形式（认不出的地址族为空串）。
        case connection(Descriptor, peer: String)
        /// 队列空了，等下一次可读事件。
        case wouldBlock
        /// 被信号打断或对端在排队时就走了，接着 accept。
        case retry
        /// 别的错误（EMFILE / ENFILE 之类）。
        case failed(Int32)
    }

    static func acceptConnection(_ listener: Descriptor) -> Accepted {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let client = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
        }
        guard client >= 0 else {
            let code = errno
            switch code {
            case EINTR, ECONNABORTED: return .retry
            case EAGAIN, EWOULDBLOCK: return .wouldBlock
            default: return .failed(code)
            }
        }
        // Glibc 的 Swift 模块没导出 accept4，只能事后补：Linux 上 accept 出来的 fd 不继承这两个标志。
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        do {
            try setNonBlocking(client)
        } catch {
            _ = close(client)
            return .retry
        }
        return .connection(client, peer: describe(&storage))
    }

    enum ReadResult {
        case data(Data)
        case endOfStream
        case wouldBlock
        case failed(Int32)
    }

    static func receive(_ descriptor: Descriptor, maximum: Int) -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: maximum)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count > 0 { return .data(Data(buffer[0..<count])) }
            if count == 0 { return .endOfStream }
            let code = errno
            switch code {
            case EINTR: continue
            case EAGAIN, EWOULDBLOCK: return .wouldBlock
            default: return .failed(code)
            }
        }
    }

    /// 写完为止；写缓冲满了就 poll 等可写，一次最多等 `timeout`。false = 对端不在了或一直不读。
    /// `MSG_NOSIGNAL`：对端关了再写只返回 EPIPE，不给整个进程发 SIGPIPE（Linux 上 Foundation 并不替我们忽略它）。
    static func writeAll(_ descriptor: Descriptor, _ data: Data, timeout: TimeInterval) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = send(descriptor, base + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                if written < 0, code == EINTR { continue }
                guard written < 0, code == EAGAIN || code == EWOULDBLOCK else { return false }
                guard wait(descriptor, events: Int16(POLLOUT), timeout: timeout) else { return false }
            }
            return true
        }
    }

    /// 关写端（FIN）。对端读到 EOF，我们这边还能继续读。
    static func shutdownWrite(_ descriptor: Descriptor) {
        _ = shutdown(descriptor, Int32(SHUT_WR))
    }

    static func closeSocket(_ descriptor: Descriptor) {
        _ = close(descriptor)
    }

    // MARK: - 地址

    /// IPv4 文本 → 4 字节（网络序）。认不出返回 nil。
    static func ipv4Bytes(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// IPv6 文本 → 16 字节。认不出返回 nil。
    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    // MARK: - 小工具

    private static func setNonBlocking(_ descriptor: Descriptor) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure(call: "fcntl(O_NONBLOCK)", code: errno)
        }
    }

    private static func wait(_ descriptor: Descriptor, events: Int16, timeout: TimeInterval) -> Bool {
        var watch = pollfd(fd: descriptor, events: events, revents: 0)
        while true {
            let ready = poll(&watch, 1, Int32(timeout * 1000))
            if ready > 0 { return watch.revents & (events | Int16(POLLERR) | Int16(POLLHUP)) != 0 }
            if ready < 0, errno == EINTR { continue }
            return false
        }
    }

    private static func describe(_ storage: inout sockaddr_storage) -> String {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        let family = Int32(storage.ss_family)
        let converted: UnsafePointer<CChar>? = withUnsafePointer(to: &storage) { pointer in
            switch family {
            case AF_INET:
                return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                    var raw = address.pointee.sin_addr
                    return inet_ntop(AF_INET, &raw, &text, socklen_t(text.count))
                }
            case AF_INET6:
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { address in
                    var raw = address.pointee.sin6_addr
                    return inet_ntop(AF_INET6, &raw, &text, socklen_t(text.count))
                }
            default:
                return nil
            }
        }
        guard converted != nil else { return "" }
        return String(cString: text)
    }
}
#endif // !canImport(Network) && !os(Windows)
