import Foundation
import os

public extension JSONValue {
    /// 单行 JSON（键排序、不转义 `/`），给按行分帧的 ACP 用。字符串里的换行会被转义，不会断行。
    /// 编码失败就抛错，不悄悄退化成字面 `"null"`——那种回退是个陷阱：对端会把它当成一条真实消息处理。
    public func acpLineOrThrow() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

/// JSON-RPC 2.0 的一个错误对象。对端回来的错误原样转成它；我们自己的请求处理器抛它，对端就收到同样的 code。
public struct JSONRPCError: Error, Hashable, Sendable, LocalizedError {
    public static let parseError = -32700
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }

    public init(json: JSONValue) {
        code = json["code"]?.intValue.map { Int($0) } ?? Self.internalError
        message = json["message"]?.stringValue ?? "未知错误"
        data = json["data"]
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["code": .int(Int64(code)), "message": .string(message)]
        if let data { object["data"] = data }
        return .object(object)
    }
}

/// 连接层面的失败：等太久，连接断了，或者这条消息压根编不成 JSON。
public enum JSONRPCPeerError: Error, Hashable, Sendable, LocalizedError {
    case timeout(method: String)
    case closed(reason: String)
    /// 请求的 `params` 编不成 JSON（比如塞了 `NaN`/`Infinity`）：宁可本地抛错，也不能把 `null` 发给对端。
    case unencodable(method: String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let method): "等 \(method) 的回应超时"
        case .closed(let reason): reason
        case .unencodable(let method): "\(method) 的参数无法编码成 JSON"
        }
    }
}

/// JSON-RPC 2.0 的一端，按行分帧（ACP 的 stdio 与反向 socket 都是一行一条消息）。
///
/// 不关心底下是管道还是 socket：要发的行交给 `send`（不带换行，传输层自己补），收到的字节经 `receive(_:)` 喂进来。
///
/// 几条约定：
/// - `receive(_:)` **必须由单个循环串行调用**。通知按到达顺序处理，处理器返回之前不会处理下一条——
///   `session/update` 的顺序就是对话的顺序。
/// - 对端发来的**请求**在独立的 Task 里处理：审批要等手机上的人，不能堵住后面的通知。
/// - **通知处理器不能反过来对同一个 peer 发 `request` 并等它的应答**：应答要靠这同一条 `receive` 串行循环
///   解出来，通知处理器不返回，循环就走不到应答那一行——等的其实是自己，只会超时或死等，不会死锁崩溃但也永远等不到。
/// - 超时、应答、关闭三条路径抢同一个 `OneShotContinuation`，不会二次 resume。
/// - 日志只记方法名与字节数，不记 params / result——里面是用户的会话内容。
public actor JSONRPCPeer {
    public typealias RequestHandler = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue) async -> Void
    /// 一条应答刚交给 `send` 之后同步调用：`result` 为 nil 表示回的是错误。
    /// 用来做"应答发出去之后再断开"这类事——在这里排的写一定排在这条应答后面。
    public typealias ResponseObserver = @Sendable (_ method: String, _ result: JSONValue?) -> Void

    /// 单行上限。`session/load` 重放带图的历史时一行可能很大，但不能无上限地攒。
    public static let maxLineBytes = 16 * 1024 * 1024
    private static let log = Logger(subsystem: "io.botbus.agent", category: "jsonrpc")

    private let send: @Sendable (String) -> Void
    private var buffer = Data()
    /// `buffer` 从当前 `startIndex` 起，已经确认没有换行符的前缀长度。
    ///
    /// 没有它，一行几十 MB 的大消息按小 chunk 喂进来时，每次 `receive` 都要从头把整个已攒的 `buffer`
    /// 扫一遍找换行符——n 个 chunk 就是 O(n²)。记住这个偏移量，下次只扫新追加的那一小段。
    private var scannedPrefixLength = 0
    /// 仅 DEBUG 用：`receive(_:)` 期间置真，退出时（`defer`）清掉，配合下面的 `assert` 兜底
    /// 「必须由单个循环串行调用」这条契约——循环体里横跨 `await handle(...)` 还留着 `lineStart` /
    /// `searchFrom` 这些指向 `buffer` 的索引，另一路并发的 `receive` 一旦在这个当口插进来改了 `buffer`，
    /// 这些索引就全废了，轻则解析错乱，重则越界崩溃。
    private var isReceiving = false
    private var nextId: Int64 = 1
    private var pending: [Int64: OneShotContinuation<JSONValue>] = [:]
    private var requestHandler: RequestHandler?
    private var notificationHandler: NotificationHandler?
    private var responseObserver: ResponseObserver?
    private var closedReason: String?

    public init(send: @escaping @Sendable (String) -> Void) {
        self.send = send
    }

    public var isClosed: Bool { closedReason != nil }

    public func setHandlers(request: RequestHandler?, notification: NotificationHandler?) {
        requestHandler = request
        notificationHandler = notification
    }

    public func setResponseObserver(_ observer: ResponseObserver?) {
        responseObserver = observer
    }

    /// 发一个请求并等应答。`timeout` 为 nil 时一直等（`session/prompt` 一轮可能跑几分钟）。
    ///
    /// 取消调用方的 Task **不会**让这次请求提前结束：请求早就发出去了，对端仍在处理。
    /// 真正中断一轮 ACP 会话要发 `session/cancel`（或对应的取消消息），不是本地扔掉这个 await。
    public func request(_ method: String, params: JSONValue = .object([:]),
                        timeout: TimeInterval? = nil) async throws -> JSONValue {
        if let closedReason { throw JSONRPCPeerError.closed(reason: closedReason) }
        let id = nextId
        let line: String
        do {
            line = try JSONValue.object(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
                .acpLineOrThrow()
        } catch {
            throw JSONRPCPeerError.unencodable(method: method)
        }
        nextId += 1
        let box = OneShotContinuation<JSONValue>()
        pending[id] = box
        send(line)
        let timer: Task<Void, Never>? = timeout.map { seconds in
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                _ = box.resume(throwing: JSONRPCPeerError.timeout(method: method))
            }
        }
        defer {
            timer?.cancel()
            pending.removeValue(forKey: id)
        }
        return try await box.value()
    }

    public func notify(_ method: String, params: JSONValue = .object([:])) {
        guard closedReason == nil else { return }
        guard let line = try? JSONValue.object(["jsonrpc": "2.0", "method": .string(method), "params": params]).acpLineOrThrow() else {
            Self.log.error("jsonrpc: notification unencodable, dropped")
            return
        }
        send(line)
    }

    /// 喂进收到的字节（任意切分）。见类型注释：只能由单个循环串行调用。
    ///
    /// 分帧只扫新追加的那一段（`scannedPrefixLength`），消费掉的整行也只在这次调用末尾统一挪一次
    /// （不是每认出一行就挪一次）：一个 chunk 里塞了几万条小通知时，逐行 `removeSubrange` 同样是 O(n²)。
    public func receive(_ chunk: Data) async {
        assert(!isReceiving, "JSONRPCPeer.receive(_:) 被并发调用了——必须由单个循环串行调用")
        isReceiving = true
        defer { isReceiving = false }
        buffer.append(chunk)
        var lineStart = buffer.startIndex
        var searchFrom = buffer.index(lineStart, offsetBy: min(scannedPrefixLength, buffer.count))
        while let newline = buffer[searchFrom...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[lineStart..<newline]
            lineStart = buffer.index(after: newline)
            searchFrom = lineStart
            await handle(Data(line))
        }
        scannedPrefixLength = buffer.distance(from: lineStart, to: buffer.endIndex)
        if lineStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
        if buffer.count > Self.maxLineBytes {
            Self.log.error("jsonrpc line over limit, dropped \(self.buffer.count) bytes")
            buffer.removeAll()
            scannedPrefixLength = 0
        }
    }

    /// 连接断了：所有在等的请求一起失败，之后的请求直接失败。幂等。
    public func close(reason: String) {
        guard closedReason == nil else { return }
        closedReason = reason
        for box in pending.values { _ = box.resume(throwing: JSONRPCPeerError.closed(reason: reason)) }
        pending.removeAll()
    }

    private func handle(_ rawLine: Data) async {
        guard closedReason == nil else { return }
        var line = rawLine
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        guard !line.allSatisfy({ $0 == UInt8(ascii: " ") }) else { return }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            Self.log.error("jsonrpc: undecodable line (\(line.count) bytes)")
            return
        }
        let method = message["method"]?.stringValue
        let id = message["id"].flatMap { $0.isNull ? nil : $0 }
        let params = message["params"] ?? .object([:])
        switch (method, id) {
        case let (method?, id?):
            let handler = requestHandler
            Task { [weak self] in
                let outcome: Result<JSONValue, JSONRPCError>
                do {
                    guard let handler else {
                        throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "不支持 \(method)")
                    }
                    outcome = .success(try await handler(method, params))
                } catch let error as JSONRPCError {
                    outcome = .failure(error)
                } catch {
                    outcome = .failure(JSONRPCError(code: JSONRPCError.internalError, message: error.localizedDescription))
                }
                await self?.sendResponse(id: id, method: method, outcome: outcome)
            }
        case let (method?, nil):
            await notificationHandler?(method, params)
        case let (nil, id?):
            guard let key = id.intValue else {
                Self.log.error("jsonrpc: response with non-integer id, dropped")
                return
            }
            guard let box = pending[key] else {
                Self.log.error("jsonrpc: response for unknown or already-settled id, dropped")
                return
            }
            if let error = message["error"], !error.isNull {
                _ = box.resume(throwing: JSONRPCError(json: error))
            } else {
                _ = box.resume(returning: message["result"] ?? .null)
            }
        case (nil, nil):
            // JSON-RPC 的解析错误应答常带 `id: null`：没法关联到任何一条挂起的请求，只能记一笔。
            Self.log.error("jsonrpc: message with neither method nor id, dropped")
        }
    }

    /// 把请求处理结果编码成一行发出去；编不出来（比如结果里混进了 `NaN`）就退化成一个必定能编码的
    /// `internalError` 响应，不能把 `result` 原样吞掉变成对端看到的 `null`。
    private func sendResponse(id: JSONValue, method: String, outcome: Result<JSONValue, JSONRPCError>) {
        guard closedReason == nil else { return }
        let response: JSONValue
        switch outcome {
        case .success(let value): response = .object(["jsonrpc": "2.0", "id": id, "result": value])
        case .failure(let error): response = .object(["jsonrpc": "2.0", "id": id, "error": error.json])
        }
        if let line = try? response.acpLineOrThrow() {
            send(line)
            responseObserver?(method, try? outcome.get())
            return
        }
        Self.log.error("jsonrpc: response unencodable, falling back to internalError")
        let fallback = JSONRPCError(code: JSONRPCError.internalError, message: "结果无法编码为 JSON")
        if let line = try? JSONValue.object(["jsonrpc": "2.0", "id": id, "error": fallback.json]).acpLineOrThrow() {
            send(line)
        }
        responseObserver?(method, nil)
    }
}
