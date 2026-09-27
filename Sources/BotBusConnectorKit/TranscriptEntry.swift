import Foundation
import BotBusProtocol

/// 对话里一张图的来源。读取器只负责找到它，读字节、压缩、上传都归 `MessageAttachmentUploader`。
public enum ImageSource: Hashable, Sendable {
    case file(URL)
    case data(Data, contentType: String)
}

/// 读取器的中间结果：协议里的 `Message`（附件、文件卡片还没填）加上待处理的图片与路径候选。
public struct TranscriptEntry: Hashable, Sendable {
    public var message: Message
    public var images: [ImageSource]
    /// Agent 回复里原样出现的路径文本（未校验）。只有 `role == .agent` 才有。
    public var pathCandidates: [String]

    public init(message: Message, images: [ImageSource] = [], pathCandidates: [String] = []) {
        self.message = message
        self.images = images
        self.pathCandidates = pathCandidates
    }
}

public extension ImageSource {
    /// 解析 `data:<mime>;base64,<…>`（Codex 的 `image {url}`、Hermes 的 `image_url` 都是这种）。
    ///
    /// 只认 base64 编码的 `image/*`：mime 缺省时按 RFC 2397 是 `text/plain`，不是图；
    /// 百分号编码的 data URL 装不了二进制图片，出现了也当不认识。
    public init?(dataURL: String) {
        let trimmed = dataURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 5, trimmed.prefix(5).lowercased() == "data:",
              let comma = trimmed.firstIndex(of: ",") else { return nil }
        let header = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<comma]
        let parts = header.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let mime = parts.first, parts.dropFirst().contains("base64") else { return nil }
        self.init(base64: String(trimmed[trimmed.index(after: comma)...]), contentType: mime)
    }

    /// 裸 base64 加类型（Claude 的 `source {media_type, data}`、Pi / OpenClaw 的 `{data, mimeType}`）。
    /// 类型不是 `image/*`、解不出或解出来是空的都返回 nil——读取器据此直接跳过，不占位。
    public init?(base64: String, contentType: String) {
        let type = contentType.trimmingCharacters(in: .whitespaces).lowercased()
        guard type.hasPrefix("image/"), type.count > "image/".count else { return nil }
        // 有的来源会按 76 列折行，先去掉空白再严格解码。
        let compact = base64.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compact), !data.isEmpty else { return nil }
        self = .data(data, contentType: type)
    }
}
