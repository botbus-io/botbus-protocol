#if os(Windows)
import Foundation
import WinSDK

/// Windows 上 `LocalHookServer` 用到的全部 TCP 系统调用（Winsock）。与 `LoopbackSocket.swift`（Linux）同名同形，
/// 只是 socket 是阻塞的：Windows 的监听与连接各有自己的线程（见 `LocalHookServer+Windows.swift`），
/// 不靠 `DispatchSource` 的可读事件。
enum LoopbackSocket {
    typealias Descriptor = SOCKET

    static let invalid: Descriptor = ~Descriptor(0)

    struct Failure: Error, CustomStringConvertible, Sendable {
        let call: String
        let code: Int32

        var description: String { "\(call): \(Win32.errorMessage(DWORD(bitPattern: code))) (WSA \(code))" }
    }

    /// 绑 `127.0.0.1:port`（0 = 让系统挑）并开始监听，返回监听 socket 与实际端口。
    ///
    /// 设 `SO_EXCLUSIVEADDRUSE`：Windows 的 `SO_REUSEADDR` 允许别的进程抢绑同一个端口，正好反过来；
    /// 独占才与 macOS / Linux 上"不允许两个监听共用一个端口"一致。TIME_WAIT 在 Windows 上不挡 bind。
    static func makeListener(port: UInt16, backlog: Int32) throws -> (descriptor: Descriptor, port: UInt16) {
        Win32.startWinsock()
        let descriptor = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
        guard descriptor != invalid else { throw Failure(call: "socket", code: WSAGetLastError()) }
        do {
            var on: Int32 = 1
            let exclusive = ~SO_REUSEADDR // SO_EXCLUSIVEADDRUSE 是 `((int)(~SO_REUSEADDR))`，宏没导进来
            let set = withUnsafePointer(to: &on) {
                $0.withMemoryRebound(to: CChar.self, capacity: 4) {
                    setsockopt(descriptor, SOL_SOCKET, exclusive, $0, Int32(MemoryLayout<Int32>.size))
                }
            }
            guard set == 0 else { throw Failure(call: "setsockopt(SO_EXCLUSIVEADDRUSE)", code: WSAGetLastError()) }
            var address = sockaddr_in()
            address.sin_family = ADDRESS_FAMILY(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian // 127.0.0.1
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw Failure(call: "bind", code: WSAGetLastError()) }
            guard listen(descriptor, backlog) == 0 else { throw Failure(call: "listen", code: WSAGetLastError()) }

            var actual = sockaddr_in()
            var length = Int32(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            guard named == 0 else { throw Failure(call: "getsockname", code: WSAGetLastError()) }
            return (descriptor, UInt16(bigEndian: actual.sin_port))
        } catch {
            closesocket(descriptor)
            throw error
        }
    }

    enum Accepted {
        case connection(Descriptor, peer: String)
        /// 对端在排队时就走了，接着 accept。
        case retry
        /// 监听 socket 已被关掉（`cancel()`）或别的错误。
        case failed(Int32)
    }

    /// 阻塞到有新连接为止。
    static func acceptConnection(_ listener: Descriptor) -> Accepted {
        var storage = sockaddr_storage()
        var length = Int32(MemoryLayout<sockaddr_storage>.size)
        let client = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
        }
        guard client != invalid else {
            let code = WSAGetLastError()
            if code == WSAECONNRESET || code == WSAEINTR { return .retry }
            return .failed(code)
        }
        return .connection(client, peer: describe(&storage))
    }

    enum ReadResult {
        case data(Data)
        case endOfStream
        case failed(Int32)
    }

    /// 阻塞读一次。
    static func receive(_ descriptor: Descriptor, maximum: Int) -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: maximum)
        let count = buffer.withUnsafeMutableBytes {
            recv(descriptor, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32($0.count), 0)
        }
        if count > 0 { return .data(Data(buffer[0..<Int(count)])) }
        if count == 0 { return .endOfStream }
        return .failed(WSAGetLastError())
    }

    /// 写完为止（阻塞 socket，`SO_SNDTIMEO` 兜住一直不读的对端）。false = 对端不在了。Windows 没有 SIGPIPE。
    static func writeAll(_ descriptor: Descriptor, _ data: Data, timeout: TimeInterval) -> Bool {
        setTimeout(descriptor, option: SO_SNDTIMEO, seconds: timeout)
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return true }
            var offset = 0
            while offset < raw.count {
                let written = send(descriptor, base + offset, Int32(min(raw.count - offset, Int(Int32.max))), 0)
                guard written > 0 else { return false }
                offset += Int(written)
            }
            return true
        }
    }

    /// 读超时：收尾排空对端剩余字节时用，免得一直等一个不发 FIN 的对端。
    static func setReceiveTimeout(_ descriptor: Descriptor, seconds: TimeInterval) {
        setTimeout(descriptor, option: SO_RCVTIMEO, seconds: seconds)
    }

    private static func setTimeout(_ descriptor: Descriptor, option: Int32, seconds: TimeInterval) {
        // Winsock 的超时是毫秒数的 DWORD，不是 timeval。
        var milliseconds = DWORD(max(1, seconds * 1000))
        _ = withUnsafePointer(to: &milliseconds) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) {
                setsockopt(descriptor, SOL_SOCKET, option, $0, Int32(MemoryLayout<DWORD>.size))
            }
        }
    }

    /// 关写端（FIN）。
    static func shutdownWrite(_ descriptor: Descriptor) {
        _ = shutdown(descriptor, SD_SEND)
    }

    /// 两头都关：别的线程上阻塞着的 `recv` / `accept` 会马上返回。
    static func shutdownBoth(_ descriptor: Descriptor) {
        _ = shutdown(descriptor, SD_BOTH)
    }

    static func closeSocket(_ descriptor: Descriptor) {
        _ = closesocket(descriptor)
    }

    // MARK: - 地址

    static func ipv4Bytes(_ text: String) -> [UInt8]? {
        Win32.startWinsock()
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        Win32.startWinsock()
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func describe(_ storage: inout sockaddr_storage) -> String {
        var text = [CChar](repeating: 0, count: 64)
        let family = Int32(storage.ss_family)
        let converted: UnsafePointer<CChar>? = withUnsafeMutablePointer(to: &storage) { pointer in
            switch family {
            case AF_INET:
                return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                    var raw = address.pointee.sin_addr
                    return inet_ntop(AF_INET, &raw, &text, text.count)
                }
            case AF_INET6:
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { address in
                    var raw = address.pointee.sin6_addr
                    return inet_ntop(AF_INET6, &raw, &text, text.count)
                }
            default:
                return nil
            }
        }
        guard converted != nil else { return "" }
        return String(cString: text)
    }
}
#endif
