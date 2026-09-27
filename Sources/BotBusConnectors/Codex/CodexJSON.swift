import Foundation
import BotBusConnectorKit

/// app-server 的请求 id：**可能是字符串也可能是整数**，两种都要认，回复时必须原样回去。
/// 我们自己发出去的一律用整数，但服务端发来的请求（审批）就见过字符串。
public enum CodexRequestID: Hashable, Sendable {
    case number(Int64)
    case text(String)

    /// 字典键与对外的 `PendingRequest.id`。加前缀是为了让整数 `5` 与字符串 `"5"` 不撞车。
    public var key: String {
        switch self {
        case .number(let value): return "#\(value)"
        case .text(let value): return "$\(value)"
        }
    }

    public init?(key: String) {
        guard let marker = key.first else { return nil }
        let rest = String(key.dropFirst())
        switch marker {
        case "#":
            guard let value = Int64(rest) else { return nil }
            self = .number(value)
        case "$":
            self = .text(rest)
        default:
            return nil
        }
    }
}

extension CodexRequestID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) { self = .number(value); return }
        self = .text(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }
}

public extension CodexRequestID {
    var jsonValue: JSONValue {
        switch self {
        case .number(let value): return .int(value)
        case .text(let value): return .string(value)
        }
    }
}

/// 一行 NDJSON 解出来的东西。**没有 `jsonrpc` 字段**——codex app-server 的分帧就是
/// "一行一个 JSON 对象"，既没有 Content-Length 头，也不带 JSON-RPC 的版本号。
public enum CodexIncomingMessage: Hashable, Sendable {
    /// 对我们某条请求的成功应答。
    case response(id: CodexRequestID, result: JSONValue)
    /// 对我们某条请求的错误应答。
    case failure(id: CodexRequestID, code: Int, message: String)
    /// 服务端主动发来的**请求**（审批、要用户输入）。有 id，必须回，但绝不自动回。
    case request(id: CodexRequestID, method: String, params: JSONValue)
    /// 服务端通知。没有 id，不用回。
    case notification(method: String, params: JSONValue)

    private struct Envelope: Decodable {
        struct Failure: Decodable {
            var code: Int?
            var message: String?
        }
        var id: CodexRequestID?
        var method: String?
        var params: JSONValue?
        var result: JSONValue?
        var error: Failure?
    }

    public init?(line: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else { return nil }
        if let method = envelope.method {
            if let id = envelope.id {
                self = .request(id: id, method: method, params: envelope.params ?? .null)
            } else {
                self = .notification(method: method, params: envelope.params ?? .null)
            }
            return
        }
        guard let id = envelope.id else { return nil }
        if let error = envelope.error {
            self = .failure(id: id, code: error.code ?? 0, message: error.message ?? "app-server 未说明原因")
            return
        }
        self = .response(id: id, result: envelope.result ?? .null)
    }

    /// 只给日志用的一句话：**只有种类、方法名与 id**，绝不带 params/result 本体。
    public var logDescription: String {
        switch self {
        case .response(let id, _): return "response \(id.key)"
        case .failure(let id, let code, _): return "error \(id.key) code=\(code)"
        case .request(let id, let method, _): return "request \(method) \(id.key)"
        case .notification(let method, _): return "notification \(method)"
        }
    }
}

/// 我们发出去的一行。同样不带 `jsonrpc`。
public enum CodexOutgoingMessage: Sendable {
    case request(id: CodexRequestID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: CodexRequestID, result: JSONValue)
    case failure(id: CodexRequestID, code: Int, message: String)

    /// 编码成一行（不含换行符）。键排序，输出稳定，测试好断言。
    public func encoded() throws -> Data {
        var object: [String: JSONValue] = [:]
        switch self {
        case .request(let id, let method, let params):
            object["id"] = id.jsonValue
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .notification(let method, let params):
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .response(let id, let result):
            object["id"] = id.jsonValue
            object["result"] = result
        case .failure(let id, let code, let message):
            object["id"] = id.jsonValue
            object["error"] = .object(["code": .int(Int64(code)), "message": .string(message)])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(object))
    }

    public var logDescription: String {
        switch self {
        case .request(let id, let method, _): return "request \(method) \(id.key)"
        case .notification(let method, _): return "notification \(method)"
        case .response(let id, _): return "response \(id.key)"
        case .failure(let id, let code, _): return "error \(id.key) code=\(code)"
        }
    }
}
