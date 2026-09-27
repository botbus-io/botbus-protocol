import Foundation

/// 任务失败后，电脑发现系统授权弹窗时留下的历史证据（协议 2.10）。
/// 不能据此认定失败原因，也不表示弹窗现在仍待处理；客户端负责提供本地化的操作说明。
public struct SystemPermissionNotice: Codable, Hashable, Sendable {
    public var id: String
    public var detectedAt: String
    /// 弹窗的原始文字，由生产方限制长度；不当作界面说明文案翻译。
    public var dialogText: String
    /// 仅匹配到的授权窗口截图，字节通过现有产物端点读取；无法截图时省略。
    public var screenshot: Artifact?

    public init(id: String, detectedAt: String, dialogText: String, screenshot: Artifact? = nil) {
        self.id = id
        self.detectedAt = detectedAt
        self.dialogText = dialogText
        self.screenshot = screenshot
    }
}
