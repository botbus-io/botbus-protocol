import Foundation
import UniformTypeIdentifiers

/// 按扩展名定 contentType；认不得的一律 `application/octet-stream`。
/// 对话记录里的文件候选（Kit）与产物上传（AgentCore）共用一份，别各写一张扩展名表。
public enum MediaType {
    public static func contentType(forPathExtension pathExtension: String) -> String {
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension.lowercased()),
              let mime = type.preferredMIMEType else { return "application/octet-stream" }
        return mime
    }
}
