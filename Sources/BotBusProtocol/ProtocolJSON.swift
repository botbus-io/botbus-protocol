import Foundation

/// 三端统一的 JSON 编解码配置。键排序保证输出稳定，便于测试与 diff。
public enum ProtocolJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// 协议规定的时间格式：秒精度 UTC、不带小数（`YYYY-MM-DDTHH:MM:SSZ`）。三端都用这里生成，字典序即时间序。
    public static func timestamp(_ date: Date = Date()) -> String {
        date.formatted(.iso8601)
    }
}
