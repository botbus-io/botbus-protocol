#if os(Windows)
import Foundation
import WinSDK

/// Windows 的本机 Unix socket（反向扩展用）：Winsock 的 AF_UNIX（Windows 10 1803 起），与 `UnixSocket.swift`
/// 同名同 API。socket 是阻塞的，监听一个线程、每条连接一个读线程。
///
/// 权限：目录与 socket 文件都收紧成只给本人的 DACL（0700 / 0600 的对应物），accept 后再用
/// `SIO_AF_UNIX_GETPEERPID` 拿到对端进程，比对它的用户 SID——与 Linux 的 `SO_PEERCRED` 同一道闸。
public final class UnixSocketServer: @unchecked Sendable {
    public static let acceptBackoff: TimeInterval = 1
    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "acp")

    private let path: String
    private let onConnection: @Sendable (UnixSocketConnection) -> Void
    private let lock = NSLock()
    private var listener: SOCKET = UnixSocketServer.invalid
    private var running = false

    static let invalid: SOCKET = ~SOCKET(0)
    /// `sockaddr_un`：`ADDRESS_FAMILY sun_family; char sun_path[108];`（afunix.h 不在 Swift 的 WinSDK 模块里）。
    static let pathCapacity = 108
    static let addressSize = 2 + pathCapacity
    /// `_WSAIOR(IOC_VENDOR, 256)`。
    static let getPeerPID: DWORD = 0x5800_0100

    public init(path: String, onConnection: @escaping @Sendable (UnixSocketConnection) -> Void) {
        self.path = path
        self.onConnection = onConnection
    }

    deinit { stop() }

    public func start() throws {
        try lock.withLock {
            guard !running else { return }
            try Self.prepareDirectory((path as NSString).deletingLastPathComponent)
            try Self.removeStaleSocket(path)
            let descriptor = try Self.makeSocket()
            do {
                let bound = try Self.withAddress(path) { bind(descriptor, $0, Int32(Self.addressSize)) }
                guard bound == 0 else { throw Self.posixError(WSAGetLastError()) }
                try? Win32.restrictToCurrentUser(path: path, directory: false)
                guard listen(descriptor, 16) == 0 else { throw Self.posixError(WSAGetLastError()) }
            } catch {
                closesocket(descriptor)
                _ = Win32.withWide(path) { DeleteFileW($0) }
                throw error
            }
            listener = descriptor
            running = true
            let thread = Thread { [self] in acceptLoop(descriptor) }
            thread.name = "botbus-acp-accept"
            thread.start()
        }
    }

    public func stop() {
        let descriptor: SOCKET? = lock.withLock {
            guard running else { return nil }
            running = false
            defer { listener = Self.invalid }
            return listener
        }
        guard let descriptor else { return }
        closesocket(descriptor)
        _ = Win32.withWide(path) { DeleteFileW($0) }
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func acceptLoop(_ descriptor: SOCKET) {
        var logged = false
        while isRunning {
            let client = accept(descriptor, nil, nil)
            guard client != Self.invalid else {
                guard isRunning else { return }
                let code = WSAGetLastError()
                if code == WSAECONNRESET || code == WSAEINTR { continue }
                if !logged {
                    logged = true
                    Self.log.error("acp socket accept failed (WSA \(code, privacy: .public)); pausing")
                }
                Thread.sleep(forTimeInterval: Self.acceptBackoff)
                continue
            }
            logged = false
            guard Self.verifyPeerIdentity(client) else {
                closesocket(client)
                continue
            }
            onConnection(UnixSocketConnection(descriptor: client))
        }
    }

    /// 对端进程的用户 SID 与本进程相同才放行；认不出对端是谁一律拒绝。
    private static func verifyPeerIdentity(_ descriptor: SOCKET) -> Bool {
        var pid: ULONG = 0
        var returned: DWORD = 0
        let status = WSAIoctl(descriptor, getPeerPID, nil, 0, &pid, DWORD(MemoryLayout<ULONG>.size), &returned, nil, nil)
        guard status == 0, pid != 0, let mine = Win32.currentUserSID else { return false }
        return Win32.userSID(ofProcess: DWORD(pid)) == mine
    }

    // MARK: - 小工具

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>) -> T) throws -> T {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < pathCapacity else { throw POSIXError(.ENAMETOOLONG) }
        var storage = [UInt8](repeating: 0, count: addressSize)
        storage[0] = UInt8(AF_UNIX & 0xFF)
        storage[1] = UInt8((AF_UNIX >> 8) & 0xFF)
        storage.replaceSubrange(2..<(2 + bytes.count), with: bytes)
        return storage.withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: sockaddr.self)) }
    }

    public static func makeSocket() throws -> SOCKET {
        Win32.startWinsock()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor != invalid else { throw posixError(WSAGetLastError()) }
        return descriptor
    }

    /// Winsock 的错误（Windows 的 `POSIXErrorCode` 没有 socket 那几种 errno，照原样报 WSA 错误码与说明）。
    public static func posixError(_ code: Int32, call: String = "socket") -> Error {
        Win32.Failure(call, code: DWORD(bitPattern: code))
    }

    private static func prepareDirectory(_ directory: String) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw POSIXError(.ENOTDIR) }
            // 软链接 / junction 指出去的目录不用：真实路径得和给的一样。
            let attributes = Win32.withWide(directory) { GetFileAttributesW($0) }
            guard attributes != INVALID_FILE_ATTRIBUTES, attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
                throw POSIXError(.EACCES)
            }
        }
        do {
            try Win32.makePrivateDirectory(URL(fileURLWithPath: directory, isDirectory: true))
        } catch {
            throw POSIXError(.EACCES)
        }
    }

    /// Windows 上 AF_UNIX 的 socket 文件是一个重解析点。有人在听就不抢；连不上才是上次没清掉的旧文件；
    /// 不是重解析点（普通文件）不删。
    private static func removeStaleSocket(_ path: String) throws {
        let attributes = Win32.withWide(path) { GetFileAttributesW($0) }
        guard attributes != INVALID_FILE_ATTRIBUTES else { return }
        guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0,
              attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0 else { throw POSIXError(.EEXIST) }
        if isListening(path) { throw posixError(WSAEADDRINUSE, call: "bind") }
        guard Win32.withWide(path, { DeleteFileW($0) }) else { throw POSIXError(.EACCES) }
    }

    private static func isListening(_ path: String) -> Bool {
        guard let descriptor = try? makeSocket() else { return false }
        defer { closesocket(descriptor) }
        return (try? withAddress(path) { connect(descriptor, $0, Int32(addressSize)) }) == 0
    }
}

/// 一条 socket 连接：读到的字节按顺序交给 `onData`，连接结束时调一次 `onClose`；写排在一条串行队列上。
///
/// 句柄的生命周期：`close()` 先两头 shutdown（卡在读或写上的调用立刻返回），真正的 `closesocket` 等读线程退出、
/// 写队列排空之后才做，句柄值不会在还有人用的时候被系统复用。
public final class UnixSocketConnection: @unchecked Sendable {
    public static let readChunk = 64 * 1024

    public let id = Foundation.UUID()
    private let descriptor: SOCKET
    private let writeQueue = DispatchQueue(label: "io.botbus.agent.acp.write")
    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var handleClosed = false
    private var onClose: (@Sendable () -> Void)?

    public init(descriptor: SOCKET) {
        self.descriptor = descriptor
    }

    deinit {
        if !handleClosed { closesocket(descriptor) }
    }

    public static func connect(path: String) throws -> UnixSocketConnection {
        let descriptor = try UnixSocketServer.makeSocket()
        do {
            let connected = try UnixSocketServer.withAddress(path) {
                WinSDK.connect(descriptor, $0, Int32(UnixSocketServer.addressSize))
            }
            guard connected == 0 else { throw UnixSocketServer.posixError(WSAGetLastError()) }
        } catch {
            closesocket(descriptor)
            throw error
        }
        return UnixSocketConnection(descriptor: descriptor)
    }

    public var isClosed: Bool { lock.withLock { closed } }

    public func start(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        let closedAlready: Bool = lock.withLock {
            guard !started else { return false }
            started = true
            guard !closed else { return true }
            self.onClose = onClose
            return false
        }
        if closedAlready {
            onClose()
            return
        }
        let thread = Thread { [self] in readLoop(onData) }
        thread.name = "botbus-acp-read"
        thread.start()
    }

    public func write(_ line: String) {
        var data = Data(line.utf8)
        data.append(UInt8(ascii: "\n"))
        writeQueue.async {
            guard !self.isClosed else { return }
            let complete = data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return true }
                var offset = 0
                while offset < raw.count {
                    let written = send(self.descriptor, base + offset, Int32(min(raw.count - offset, Int(Int32.max))), 0)
                    guard written > 0 else { return false }
                    offset += Int(written)
                }
                return true
            }
            if !complete { self.close() }
        }
    }

    public func closeAfterPendingWrites() {
        writeQueue.async { self.close() }
    }

    public func close() {
        let taken: (onClose: (@Sendable () -> Void)?, reading: Bool)? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            defer { onClose = nil }
            return (onClose, started)
        }
        guard let taken else { return }
        shutdown(descriptor, SD_BOTH)
        // 读线程在跑的话由它退出时关句柄；从没 start 过就在这里（写队列排空后）关。
        if !taken.reading { writeQueue.async { self.closeHandle() } }
        taken.onClose?()
    }

    private func closeHandle() {
        let first: Bool = lock.withLock {
            guard !handleClosed else { return false }
            handleClosed = true
            return true
        }
        if first { closesocket(descriptor) }
    }

    private func readLoop(_ onData: @Sendable (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: Self.readChunk)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32($0.count), 0)
            }
            guard count > 0 else { break }
            onData(Data(buffer[0..<Int(count)]))
        }
        close()
        writeQueue.async { self.closeHandle() }
    }
}
#endif
