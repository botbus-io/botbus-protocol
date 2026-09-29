import Foundation

#if canImport(os)
import os

/// On Apple platforms, reuse os.Logger unchanged.
public typealias PlatformLogger = Logger
#else
/// Linux / Windows 上 `os.Logger` 的替身：一行一条写到 stderr（systemd 下进 journald），前缀是 subsystem 与 category。
///
/// 插值语法与 `os.Logger` 相同（`\(value, privacy: .public)`），调用处不用到处包 `#if`。
/// **隐私语义也照搬 os.Logger**——多用户服务器上 journald 或重定向出来的日志文件未必只有本人看得到：
/// - `.public` 原样打印；`.private` 打成 `<private>`；
/// - 不标注时，整数、浮点、Bool 与不带关联值的枚举原样打印，其余（String、Error、URL、任意
///   `CustomStringConvertible`……）一律 `<private>`。
///
/// 排查问题时设环境变量 `BOTBUS_LOG_PRIVATE=1` 关掉脱敏（进程启动时读一次）。
public struct PlatformLogger: Sendable {
    private let prefix: String

    public init(subsystem: String, category: String) {
        self.prefix = "[\(subsystem):\(category)]"
    }

    public func info(_ message: LogMessage) { _log("INFO", message) }
    public func error(_ message: LogMessage) { _log("ERROR", message) }
    public func debug(_ message: LogMessage) { _log("DEBUG", message) }
    public func notice(_ message: LogMessage) { _log("NOTE", message) }
    public func warning(_ message: LogMessage) { _log("WARN", message) }
    public func fault(_ message: LogMessage) { _log("FAULT", message) }

    private func _log(_ level: String, _ message: LogMessage) {
        let line = "\(prefix) \(level): \(message.text)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// 对应 `OSLogMessage` 的字符串插值，按上面的规则脱敏。
public struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    /// 脱敏的占位符，和 os.Logger 一样。
    public static let redacted = "<private>"

    /// `BOTBUS_LOG_PRIVATE=1` 时不脱敏。
    static let revealsPrivate: Bool = ProcessInfo.processInfo.environment["BOTBUS_LOG_PRIVATE"] == "1"

    public let text: String

    public init(stringLiteral value: String) { self.text = value }
    public init(stringInterpolation: StringInterpolation) { self.text = stringInterpolation.result }

    public struct StringInterpolation: StringInterpolationProtocol {
        var result = ""
        /// 测试用：不读环境变量，直接指定。
        let revealsPrivate: Bool

        public init(literalCapacity: Int, interpolationCount: Int) {
            self.init(literalCapacity: literalCapacity, revealsPrivate: LogMessage.revealsPrivate)
        }

        init(literalCapacity: Int, revealsPrivate: Bool) {
            self.revealsPrivate = revealsPrivate
            result.reserveCapacity(literalCapacity)
        }

        public mutating func appendLiteral(_ literal: String) {
            result.append(literal)
        }

        // 数值与 Bool：不标注时公开（os.Logger 同样如此）。
        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T, privacy: LogPrivacy = .auto) {
            append(String(describing: value), isPublic: privacy != .private)
        }

        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, privacy: LogPrivacy = .auto) {
            append(String(describing: value), isPublic: privacy != .private)
        }

        public mutating func appendInterpolation(_ value: Bool, privacy: LogPrivacy = .auto) {
            append(String(describing: value), isPublic: privacy != .private)
        }

        // 其余一切：不标注时只有不带关联值的枚举公开。
        public mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .auto) {
            let isPublic: Bool
            switch privacy {
            case .public: isPublic = true
            case .private: isPublic = false
            case .auto: isPublic = Self.isPayloadFreeEnum(value)
            }
            append(String(describing: value), isPublic: isPublic)
        }

        private mutating func append(_ text: @autoclosure () -> String, isPublic: Bool) {
            result.append(isPublic || revealsPrivate ? text() : LogMessage.redacted)
        }

        /// `case idle` 这种：Mirror 认得出是枚举且没有子节点。带关联值的（`.failed(reason)`）照样脱敏。
        static func isPayloadFreeEnum<T>(_ value: T) -> Bool {
            let mirror = Mirror(reflecting: value)
            return mirror.displayStyle == .enum && mirror.children.isEmpty
        }
    }
}

/// `OSLogPrivacy` 的替身，只有代码里用到的几种。
public enum LogPrivacy: Sendable, Equatable {
    case `public`
    case `private`
    case auto
}
#endif
