import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// 按扩展名定 contentType；认不得的一律 `application/octet-stream`。
/// 对话记录里的文件候选（Kit）与产物上传（AgentCore）共用一份，别各写一张扩展名表。
///
/// Apple 平台只问 UniformTypeIdentifiers；没有它的平台（Linux、Windows）查 `portableTypes`。
/// 表里凡是 UTType 给得出 MIME 的扩展名，都与 macOS 的答案逐字相同（`MediaTypeTests` 在 Mac 上核对），
/// 这样同一个文件在两种电脑上分享出去是同一种产物（图片 / 视频 / 文件）。
public enum MediaType {
    public static func contentType(forPathExtension pathExtension: String) -> String {
        guard !pathExtension.isEmpty else { return "application/octet-stream" }
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: pathExtension.lowercased()),
           let mime = type.preferredMIMEType { return mime }
        return "application/octet-stream"
        #else
        return portableContentType(forPathExtension: pathExtension) ?? "application/octet-stream"
        #endif
    }

    /// 两个扩展名是不是同一种类型的不同写法（`md` 与 `markdown`、`jpg` 与 `jpeg`）。
    /// Apple 平台按 UTType 判断（动态类型不算）；其余平台按 `portableTypes` 里的 MIME 相同判断。
    public static func isSameType(pathExtension first: String, _ second: String) -> Bool {
        let a = first.lowercased(), b = second.lowercased()
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        #if canImport(UniformTypeIdentifiers)
        guard let left = UTType(filenameExtension: a), let right = UTType(filenameExtension: b) else { return false }
        return left == right && !left.isDynamic
        #else
        guard let left = portableContentType(forPathExtension: a),
              let right = portableContentType(forPathExtension: b) else { return false }
        return left == right
        #endif
    }

    /// 不经 UTType 的扩展名表。公开给测试：在 Mac 上也能核对它与 UTType 一致。
    public static func portableContentType(forPathExtension pathExtension: String) -> String? {
        portableTypes[pathExtension.lowercased()]
    }

    /// BotBus 产物与对话文件里实际会遇到的类型。前三组（图片、视频、音频）决定产物种类，必须与 macOS 一致；
    /// 末尾几种源码与日志 UTType 没有 MIME（macOS 上是 `application/octet-stream`），这里给 `text/*`，
    /// 只影响手机怎么打开这份文件。`ts` 故意当 TypeScript（UTType 当 MPEG-2 传输流，但它没有 MIME）。
    /// 同一个 MIME 只给同一类型的不同写法，别让两种不同的格式撞上（`isSameType` 靠它判断）。
    static let portableTypes: [String: String] = [
        // 图片
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "heic": "image/heic", "heif": "image/heif", "bmp": "image/bmp",
        "tif": "image/tiff", "tiff": "image/tiff", "psd": "image/vnd.adobe.photoshop",
        "svg": "image/svg+xml", "avif": "image/avif", "ico": "image/vnd.microsoft.icon",
        // 视频
        "mp4": "video/mp4", "mov": "video/quicktime", "m4v": "video/x-m4v", "webm": "video/webm",
        "avi": "video/avi",
        // 音频
        "mp3": "audio/mpeg", "wav": "audio/vnd.wave", "m4a": "audio/x-m4a", "aac": "audio/aac",
        "flac": "audio/flac", "ogg": "audio/ogg",
        // 文档与数据
        "pdf": "application/pdf", "txt": "text/plain", "md": "text/markdown", "markdown": "text/markdown",
        "json": "application/json", "html": "text/html", "htm": "text/html", "css": "text/css",
        "js": "text/javascript", "mjs": "text/javascript", "csv": "text/csv",
        "tsv": "text/tab-separated-values", "xml": "application/xml", "rtf": "text/rtf",
        "yaml": "application/x-yaml", "yml": "application/x-yaml", "epub": "application/epub+zip",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        // 压缩包
        "zip": "application/zip", "tar": "application/x-tar", "gz": "application/x-gzip",
        "7z": "application/x-7z-compressed", "rar": "application/x-rar",
        // 源码与日志（UTType 没有 MIME，见上）
        "py": "text/x-python-script", "rb": "text/x-ruby-script", "swift": "text/x-swift",
        "ts": "text/x-typescript", "sh": "text/x-shellscript", "log": "text/x-log",
    ]
}
