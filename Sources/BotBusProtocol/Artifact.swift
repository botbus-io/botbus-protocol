import Foundation

/// 产物种类。闭集：遇未知值拒绝整条（与其他枚举一致，不回落默认值）。
public enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    /// 截图或其他图片，字节存在 Relay。
    case image
    /// 任意文件，字节存在 Relay。
    case file
    /// 视频，字节存在 Relay（协议 2.9）。
    case video
    /// 经 Relay 隧道打开的 localhost 预览（端口或静态目录）。
    case preview
    /// 公网链接，只有 URL，不经 Relay 存字节。
    case link
}

/// agent 回传给手机的一件产物，挂在 `TaskRecord.artifacts` 上（协议 2.3）。
///
/// 解码只校验字段类型与 `kind` 闭集。"某 kind 必填某字段"（image/file/video 的 `contentType` 与 `size`、
/// link 的 `url`、preview 的 `expiresAt`）由生产方（Agent）保证；消费方遇缺失按"不可用"显示，
/// 不拒绝整条——否则一件坏产物会让整份快照解不出来。
public struct Artifact: Codable, Hashable, Sendable, Identifiable {
    /// 标题上限，生产方负责截断。
    public static let maxTitleLength = 80

    /// image / file / video / link：Agent 生成的 22 字符 base64url（16 随机字节）；
    /// preview：Relay 分配的 26 字符小写 base32（`[a-z2-7]`），同时是预览主机名 `p-<id>` 的一部分。
    public var id: String
    public var kind: ArtifactKind
    public var title: String
    public var createdAt: String
    /// image / file / video 必填，如 `image/png`。
    public var contentType: String?
    /// image / file / video 必填，字节数。
    public var size: Int?
    /// link 必填，`http` / `https`。
    public var url: String?
    /// preview 来自端口时填写（1–65535）；来自静态目录时省略。
    public var port: Int?
    /// preview 必填；image / file / video 可选（Relay 侧 TTL 到期时间）。
    public var expiresAt: String?
    /// video 可选：封面图的产物 id（协议 2.9）。只上传到 Relay，不进 `Task.artifacts`。
    public var posterId: String?
    /// video 可选：时长，单位秒（协议 2.9）。
    public var duration: Double?
    /// 协议 3.0：preview 可选，只发 true 或省略——这份预览是远程操作的电脑屏幕。手机据此用 app 包里的查看页、
    /// 注入 `K_rc` 打开（画面与输入端到端加密），而不是加载 Relay 送来的页面。
    public var remoteControl: Bool?

    public init(id: String, kind: ArtifactKind, title: String, createdAt: String,
                contentType: String? = nil, size: Int? = nil, url: String? = nil,
                port: Int? = nil, expiresAt: String? = nil,
                posterId: String? = nil, duration: Double? = nil, remoteControl: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.contentType = contentType
        self.size = size
        self.url = url
        self.port = port
        self.expiresAt = expiresAt
        self.posterId = posterId
        self.duration = duration
        self.remoteControl = remoteControl
    }
}
