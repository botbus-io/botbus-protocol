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

