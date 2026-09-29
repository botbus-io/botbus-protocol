#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib
#endif
import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 线程安全的小盒子，测试里跨任务收集数据。
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
    var current: Value { withLock { $0 } }
}

/// 轮询直到条件成立或超时。
func eventually(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// XCTest 的 autoclosure 不支持 await：先等条件再断言，失败仍归到调用行。
func assertEventually(timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
                      _ condition: @escaping () async -> Bool) async {
    let satisfied = await eventually(timeout: timeout, condition)
    XCTAssertTrue(satisfied, "condition not met within \(timeout)s", file: file, line: line)
}

/// 假连接：测试往里塞帧、模拟对端关闭，并记录 Agent 发出的文本。
final class FakeConnection: WebSocketConnection, @unchecked Sendable {
    let sent = Locked<[String]>([])
    /// 发出的事件帧：去掉协议 3.0 连上后的第一帧 `ready`（它只用来换 hello，不是事件）。
    var events: [String] { sent.current.filter { $0 != #"{"type":"ready"}"# } }
    /// 打开后 `send` 抛错：模拟"连接还在但帧发不出去"，用来验证 outbox 的入队。
    let failSends = Locked(false)
    private(set) var closed = false
    private var iterator: AsyncStream<Result<String, Error>>.Iterator
    private let continuation: AsyncStream<Result<String, Error>>.Continuation

    init() {
        var captured: AsyncStream<Result<String, Error>>.Continuation!
        let stream = AsyncStream<Result<String, Error>> { captured = $0 }
        continuation = captured
        iterator = stream.makeAsyncIterator()
    }

    func send(text: String) async throws {
        if failSends.current { throw WebSocketClosed(code: 1006, reason: "send failed") }
        sent.withLock { $0.append(text) }
    }

    func receiveText() async throws -> String {
        guard let next = await iterator.next() else { throw WebSocketClosed(code: 1006, reason: "stream ended") }
        return try next.get()
    }

    func sendPing() async throws {}

    func close() {
        closed = true
        continuation.finish()
    }

    // 测试控制
    func deliver(_ text: String) { continuation.yield(.success(text)) }
    func closeFromServer(code: Int) {
        continuation.yield(.failure(WebSocketClosed(code: code, reason: "server")))
        continuation.finish()
    }
}

/// 假传输：按预设剧本接受或拒绝握手，记录每次连接的请求头。
final class FakeTransport: WebSocketTransport, @unchecked Sendable {
    enum Plan { case accept, reject(status: Int?), fail(Error) }
    private let lock = NSLock()
    private var plans: [Plan]
    private var storedConnections: [FakeConnection] = []
    private var storedHeaders: [[String: String]] = []

    init(plans: [Plan] = []) { self.plans = plans }

    var connections: [FakeConnection] { lock.withLock { storedConnections } }
    var headers: [[String: String]] { lock.withLock { storedHeaders } }

    func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection {
        let plan: Plan = lock.withLock {
            storedHeaders.append(headers)
            return plans.isEmpty ? .accept : plans.removeFirst()
        }
        switch plan {
        case .reject(let status):
            throw WebSocketHandshakeFailed(status: status, underlying: nil)
        case .fail(let error):
            throw error
        case .accept:
            let connection = FakeConnection()
            lock.withLock { storedConnections.append(connection) }
            return connection
        }
    }
}

/// 手动闸门：wait() 挂起到 open() 被调用为止，用来把握手、取快照或命令 handler 卡在半路制造重入窗口。
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            let taken = waiters
            waiters = []
            return taken
        }
        for waiter in pending { waiter.resume() }
    }
}

/// 一张 1×1 的 PNG，给各读取器的图片块当假数据（读取器只解码 base64，不关心像素）。
enum TestImage {
    static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    static var png: Data { Data(base64Encoded: pngBase64)! }
    static var pngDataURL: String { "data:image/png;base64,\(pngBase64)" }

    // 现编图片要 ImageIO / zlib，只有 Apple 平台有；Linux 上的用例只用上面那张现成的 PNG。
    #if canImport(ImageIO)
    /// 一张全黑的 8 位灰度 PNG，尺寸随意、字节很少（1 亿像素的也只有一百来 KB）。
    /// 逐行喂给 zlib 流式压缩，不在内存里摊开整张像素——测像素上限不必真的吃掉 100 MB。
    static func blankPNG(width: Int, height: Int) -> Data {
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += pngChunk("IHDR", bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + [8, 0, 0, 0, 0])
        png += pngChunk("IDAT", deflateZeroRows(width: width, height: height))
        png += pngChunk("IEND", [])
        return Data(png)
    }

    /// 一张 `width`×`height`、两帧的 GIF（ImageIO 现编），用来确认动图原样上传。
    static func animatedGIF(width: Int, height: Int) -> Data {
        let buffer = NSMutableData()
        let destination = CGImageDestinationCreateWithData(buffer, UTType.gif.identifier as CFString, 2, nil)!
        for red in [1.0, 0.0] {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(red: red, green: 0.3, blue: 1 - red, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        }
        precondition(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func pngChunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let tagged = Array(type.utf8) + body
        let crc = tagged.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, UInt32($0.count))) }
        return bigEndian(UInt32(body.count)) + tagged + bigEndian(crc)
    }

    /// `height` 行、每行 1 字节过滤类型 + `width` 字节 0 的 zlib 流。
    private static func deflateZeroRows(width: Int, height: Int) -> [UInt8] {
        var stream = z_stream()
        precondition(deflateInit_(&stream, 9, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { deflateEnd(&stream) }
        var row = [UInt8](repeating: 0, count: 1 + width)
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        func pump(_ flush: Int32) {
            repeat {
                chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = UInt32(buffer.count)
                    _ = deflate(&stream, flush)
                }
                output += chunk.prefix(chunk.count - Int(stream.avail_out))
            } while stream.avail_out == 0
        }
        for _ in 0..<height {
            row.withUnsafeMutableBufferPointer { buffer in
                stream.next_in = buffer.baseAddress
                stream.avail_in = UInt32(buffer.count)
                pump(Z_NO_FLUSH)
            }
        }
        pump(Z_FINISH)
        return output
    }
    #endif
}
