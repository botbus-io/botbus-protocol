import CryptoKit
import Foundation
import BotBusConnectorKit

/// `dsh web` 的浏览器会话签名密钥（`~/.dsh/.credentials.yaml` 的
/// `records["client-connection/browser-session"].payload.secret`，base64url，32 字节）。
///
/// **只读这一个键**：同一文件里还有 API key 的引用（`refs`），一概不碰、不解析。密钥只留在内存里，
/// 不打日志、不进错误文案、不写盘。
public enum DshWebCredentials {
    public static let recordKey = "client-connection/browser-session"
    public static let secretBytes = 32

    /// 读文件并取出密钥。文件不在、读不了、格式不对都返回 nil（调用方当作"连不了 web"）。
    public static func loadBrowserSessionSecret(paths: DshPaths) -> SymmetricKey? {
        guard let data = try? Data(contentsOf: paths.credentialsFile) else { return nil }
        return browserSessionSecret(yaml: String(decoding: data, as: UTF8.self))
    }

    /// 最小的 YAML 读法：按缩进找 `client-connection/browser-session:` → 它下面的 `payload:` → 再下面的 `secret:`。
    /// dsh 用 js-yaml 写这个文件，块状映射、值不跨行；键名与值可以带引号。别的写法（流式 `{}`、多行值）一律不认。
    /// 解出来必须是规范的 base64url（不带 `=`、重新编码与原文一致）且恰好 32 字节，同 dsh 自己的 `canonicalSecret`。
    public static func browserSessionSecret(yaml: String) -> SymmetricKey? {
        // 0 = 找记录；1 = 在记录里找 `payload:`；2 = 在 payload 里找 `secret:`。缩进退回去就退回上一层。
        var phase = 0
        var recordIndent = 0
        var payloadIndent = 0
        for line in yaml.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let (key, value) = keyValue(trimmed) else { continue }
            let indent = line.prefix { $0 == " " }.count
            if phase == 2, indent <= payloadIndent { phase = 1 }
            if phase >= 1, indent <= recordIndent { phase = 0 }
            switch phase {
            case 0:
                if key == recordKey, value.isEmpty { recordIndent = indent; phase = 1 }
            case 1:
                if key == "payload", value.isEmpty { payloadIndent = indent; phase = 2 }
            default:
                if key == "secret" { return decode(value) }
            }
        }
        return nil
    }

    /// `key: value` → (去引号的键, 去引号的值)；没有冒号的行返回 nil。
    private static func keyValue(_ line: String) -> (String, String)? {
        var key: Substring
        var rest: Substring
        if let quote = line.first, quote == "\"" || quote == "'" {
            let body = line.dropFirst()
            guard let close = body.firstIndex(of: quote) else { return nil }
            key = body[..<close]
            rest = body[body.index(after: close)...]
            guard rest.first == ":" else { return nil }
            rest = rest.dropFirst()
        } else {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            key = line[..<colon]
            rest = line[line.index(after: colon)...]
        }
        var value = rest.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return (String(key).trimmingCharacters(in: .whitespaces), value)
    }

    private static func decode(_ text: String) -> SymmetricKey? {
        guard let data = DshBase64URL.decode(text), data.count == secretBytes else { return nil }
        return SymmetricKey(data: data)
    }
}

/// 自签 `dsh web` 的浏览器 cookie（与 `@deepseek-ai/dsh-client-connection` 的 `BrowserAuth` 同一算法）：
///
/// - 名字：`dsh-auth-<b64url(sha256(authority))>`，`authority` 是请求的 Host（`127.0.0.1:<port>`）；
/// - 值：`v1.<body>.<sig>`，`body = b64url(JSON{version:1, authority, issuedAt, expiresAt})`（毫秒），
///   `sig = b64url(HMAC-SHA256(secret, body))`。
///
/// dsh 核对 `issuedAt <= now < expiresAt` 且有效期不超过它配置的上限（按天计），所以默认签一小时、`issuedAt` 往前拨 5 秒防时钟抖动。
public enum DshWebCookie {
    public static let defaultLifetime: TimeInterval = 3600
    static let clockSkew: TimeInterval = 5

    public static func name(authority: String) -> String {
        "dsh-auth-" + DshBase64URL.encode(Data(SHA256.hash(data: Data(authority.utf8))))
    }

    /// 签名用的明文：键序固定（dsh 只验签名，不在乎键序；固定下来是为了测试向量稳定）。
    static func body(authority: String, issuedAtMs: Int64, expiresAtMs: Int64) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let authorityJSON = String(decoding: (try? encoder.encode(authority)) ?? Data("\"\"".utf8), as: UTF8.self)
        let json = #"{"version":1,"authority":\#(authorityJSON),"issuedAt":\#(issuedAtMs),"expiresAt":\#(expiresAtMs)}"#
        return DshBase64URL.encode(Data(json.utf8))
    }

    public static func value(secret: SymmetricKey, authority: String, issuedAtMs: Int64, expiresAtMs: Int64) -> String {
        let body = body(authority: authority, issuedAtMs: issuedAtMs, expiresAtMs: expiresAtMs)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: secret)
        return "v1.\(body).\(DshBase64URL.encode(Data(signature)))"
    }

    /// 整条 `Cookie` 请求头的值：`<name>=<value>`。
    public static func header(secret: SymmetricKey, authority: String, now: Date = Date(),
                              lifetime: TimeInterval = defaultLifetime) -> String {
        let issued = Int64(((now.timeIntervalSince1970 - clockSkew) * 1000).rounded(.down))
        let expires = issued + Int64(lifetime * 1000)
        return "\(name(authority: authority))=\(value(secret: secret, authority: authority, issuedAtMs: issued, expiresAtMs: expires))"
    }
}

/// 不带 `=` 的 base64url。解码只认规范写法（同 dsh 的 `decodeBase64Url`）。
enum DshBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.count % 4 != 1,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), encode(data) == text else { return nil }
        return data
    }
}
