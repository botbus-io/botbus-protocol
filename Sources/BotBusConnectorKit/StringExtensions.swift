import Foundation

public extension String {
    /// 去掉首尾空白与换行；各连接器解析上游文本时共用。
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
