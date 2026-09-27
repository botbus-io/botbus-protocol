import Foundation

/// 一段任意 JSON。app-server 的 `params` / `result` 是开放结构（每个版本都在长字段），
/// 用强类型模型去追它只会天天改；这里保留原样，需要哪个字段就按路径取。
///
/// 整数与浮点分开存：请求 id、`startedAtMs`、`exitCode` 这些必须原样回写，
/// 全塞进 `Double` 会把 `1` 写成 `1.0`，对端未必收。
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public extension JSONValue {
    var isNull: Bool { self == .null }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// `.int` 直接给；`.double` 只在恰好是整数时给（JSON 里 `1` 与 `1.0` 常常混用）。
    var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value):
            guard value.rounded() == value, value >= Double(Int64.min), value <= Double(Int64.max) else { return nil }
            return Int64(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? { objectValue?[key] }

    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// 按路径取值：`value.path("turn", "status")`。中间缺一环就是 nil，不抛错。
    func path(_ keys: String...) -> JSONValue? {
        var current: JSONValue? = self
        for key in keys { current = current?[key] }
        return current
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // 顺序要紧：JSON 的 true/false 只能解成 Bool，但 Int64 能吃下任何整数字面量，
        // 所以 Bool 必须排在数字前面，整数必须排在浮点前面。
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别的 JSON 值")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// 字面量：造 params 与写测试时少一半噪音。
extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

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

public extension CodexRequestID {
    var jsonValue: JSONValue {
        switch self {
        case .number(let value): return .int(value)
        case .text(let value): return .string(value)
        }
    }
}
