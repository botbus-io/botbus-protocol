import Foundation

/// 端到端加密（协议 3.0，`docs/superpowers/specs/2026-09-26-end-to-end-encryption-design.md`）。
///
/// 一段密文在 JSON 里是一个 base64url 字符串：`0x01 ‖ nonce(12) ‖ AES-256-GCM 密文 ‖ tag(16)`。
/// 算法只有 AES-256-GCM：CryptoKit、Node / Workers 与 Safari 的 WebCrypto 都原生支持，
/// Android（`javax.crypto`）与 Windows（.NET `AesGcm`）也有，别的实现照这一个格式做即可。
/// 首字节是格式版本；将来要"先压缩再加密"就加 `0x02`，解不认识的版本一律拒绝。
public struct Sealed: Codable, Hashable, Sendable {
    public static let formatVersion: UInt8 = 0x01
    public static let nonceLength = 12
    public static let tagLength = 16

    /// base64url（无填充）的信封文本。
    public var text: String

    public init(text: String) { self.text = text }

    public init(from decoder: Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

public enum SealingError: Error, Equatable, Sendable {
    /// 信封不是合法的 base64url，或短到装不下 nonce 与 tag。
    case malformed
    /// 格式版本不认识。
    case unsupportedVersion(UInt8)
    /// 密钥不对、AAD 不对或密文被改过：GCM 校验失败。三种情况对外不区分。
    case cannotOpen
    /// 解开的明文与信封上的明文字段不一致（例如任务 id 对不上）：Relay 改过信封外面的字段。
    case mismatch(String)
    /// 密钥长度不是 32 字节。
    case badKey
}

/// 一个组的根密钥与派生的用途密钥。根密钥 K 只在配对时经二维码 / 密钥信封传递，之后各设备各自存 Keychain。
public struct PairKey: Hashable, Sendable {
    public static let length = 32

    public let root: Data

    public init(root: Data) throws {
        guard root.count == Self.length else { throw SealingError.badKey }
        self.root = root
    }

    public static func random() -> PairKey {
        try! PairKey(root: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// base64url（无填充）文本，二维码与 Keychain 都用它。
    public var base64url: String { Base64URL.encode(root) }

    public init?(base64url text: String) {
        guard let data = Base64URL.decode(text), data.count == Self.length else { return nil }
        root = data
    }

    /// HKDF-SHA256 派生，salt 为空，`info` 是固定字符串。四把用途密钥都是 32 字节。
    public enum Purpose: String, Sendable, CaseIterable {
        /// 快照、事件、命令、结果、对话记录、产物字节。
        case content = "botbus/v1/content"
        /// 推送通知里的标题与正文；iPhone 的通知扩展只拿这一把。
        case notify = "botbus/v1/notify"
        /// 远程操作的画面与输入。
        case remoteControl = "botbus/v1/remote-control"
        /// 确定性产物 id 的 HMAC 密钥。
        case artifactId = "botbus/v1/artifact-id"
    }

    public func derived(_ purpose: Purpose) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root),
                                         info: Data(purpose.rawValue.utf8),
                                         outputByteCount: Self.length)
        return key.withUnsafeBytes { Data($0) }
    }

    /// 给人核对两台设备是不是同一把钥匙：SHA256(K) 的前 4 字节，8 位十六进制。
    public var fingerprint: String {
        SHA256.hash(data: root).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// 确定性产物 id：HMAC-SHA256(`K_id`, 输入) 截 16 字节的 base64url（22 字符）。
    /// 组内相同内容得到相同 id（复用已上传的产物），Relay 却对不上已知内容。
    public func artifactId(for input: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: derived(.artifactId)))
        return Base64URL.encode(Data(mac).prefix(16))
    }
}

/// 用一把 32 字节的用途密钥密封 / 解开。`nonce` 可注入：fixture 用 AAD 派生的固定 nonce 得到逐字节可比的输出，
/// 生产环境一律随机（默认）。
public struct Sealer: Sendable {
    public typealias NonceProvider = @Sendable (_ aad: String) -> Data

    private let key: Data
    private let nonce: NonceProvider

    public init(key: Data, nonce: @escaping NonceProvider = Sealer.randomNonce) throws {
        guard key.count == PairKey.length else { throw SealingError.badKey }
        self.key = key
        self.nonce = nonce
    }

    public init(pairKey: PairKey, purpose: PairKey.Purpose = .content, nonce: @escaping NonceProvider = Sealer.randomNonce) {
        self.key = pairKey.derived(purpose)
        self.nonce = nonce
    }

    public static let randomNonce: NonceProvider = { _ in Data(AES.GCM.Nonce()) }

    /// **只给 fixture 用**：nonce = SHA256(aad) 的前 12 字节，同一把钥匙、同一 AAD、同一明文得到同一密文。
    /// 生产环境重复 nonce 会泄露明文异或，绝不能用。
    public static let fixtureNonce: NonceProvider = { aad in
        Data(SHA256.hash(data: Data(aad.utf8)).prefix(Sealed.nonceLength))
    }

    /// 原始字节的信封：`0x01 ‖ nonce ‖ AES-256-GCM 密文 ‖ tag`，不经 base64url。画面包、文件块这类大块数据直接用它，
    /// `seal` 只是在它外面再包一层 base64url。
    public func sealRaw(_ plaintext: Data, aad: String) throws -> Data {
        let nonceBytes = nonce(aad)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                   nonce: AES.GCM.Nonce(data: nonceBytes),
                                   authenticating: Data(aad.utf8))
        var bytes = Data([Sealed.formatVersion])
        bytes.append(nonceBytes)
        bytes.append(box.ciphertext)
        bytes.append(box.tag)
        return bytes
    }

    public func openRaw(_ envelope: Data, aad: String) throws -> Data {
        guard envelope.count >= 1 + Sealed.nonceLength + Sealed.tagLength else { throw SealingError.malformed }
        let version = envelope[envelope.startIndex]
        guard version == Sealed.formatVersion else { throw SealingError.unsupportedVersion(version) }
        let nonceStart = envelope.startIndex + 1
        let cipherStart = nonceStart + Sealed.nonceLength
        let tagStart = envelope.endIndex - Sealed.tagLength
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: envelope[nonceStart..<cipherStart]),
                                            ciphertext: envelope[cipherStart..<tagStart],
                                            tag: envelope[tagStart..<envelope.endIndex])
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(aad.utf8))
        } catch {
            throw SealingError.cannotOpen
        }
    }

    public func seal(_ plaintext: Data, aad: String) throws -> Sealed {
        Sealed(text: Base64URL.encode(try sealRaw(plaintext, aad: aad)))
    }

    public func open(_ sealed: Sealed, aad: String) throws -> Data {
        guard let bytes = Base64URL.decode(sealed.text) else { throw SealingError.malformed }
        return try openRaw(bytes, aad: aad)
    }

    /// 明文是 `ProtocolJSON`（键排序）编码的 JSON。
    public func seal<T: Encodable>(_ value: T, aad: String) throws -> Sealed {
        try seal(ProtocolJSON.encoder().encode(value), aad: aad)
    }

    public func open<T: Decodable>(_ type: T.Type, from sealed: Sealed, aad: String) throws -> T {
        try ProtocolJSON.decoder().decode(type, from: open(sealed, aad: aad))
    }
}

/// 信封上的关联数据（AAD）。把密文钉在它的位置上：Relay 把 A 电脑的密文塞给 B、把旧任务的密文塞回新 id 下都会解密失败。
/// 不含 pairId：跨组挪密文本来就解不开（K 不同），而 Mac 在收到 hello 之前不知道自己的 pairId。
public enum SealingContext {
    public static func task(agentId: String, taskId: String) -> String { "task:\(agentId):\(taskId)" }
    public static func agent(agentId: String) -> String { "agent:\(agentId)" }
    public static func projects(agentId: String) -> String { "projects:\(agentId)" }
    public static func messages(agentId: String, taskId: String) -> String { "messages:\(agentId):\(taskId)" }
    public static func command(agentId: String, commandId: String) -> String { "command:\(agentId):\(commandId)" }
    public static func result(commandId: String) -> String { "result:\(commandId)" }
    public static func notify(agentId: String, taskId: String) -> String { "notify:\(agentId):\(taskId)" }
    /// 手机名在认领时还没有 clientId，所以只钉用途。
    public static let clientName = "client"
    public static func artifact(agentId: String, artifactId: String) -> String { "artifact:\(agentId):\(artifactId)" }
    public static func keyEnvelope(agentId: String) -> String { "key-envelope:\(agentId)" }
    /// 远程操作不钉预览 id：同一个工作区服务可能同时有几份预览（不同任务各一份）共用它，预览也会换，
    /// 挪用与重放靠密文里的路径与时间戳挡（见 `RemoteControlPage`）。
    public static func remoteControl(agentId: String) -> String { "rc:\(agentId)" }

    /// 3.7：带通道号 `c` 的请求，回复钉在这一条请求上——Relay 把别的请求的回复挪过来解不开。
    public static func remoteControlResponse(agentId: String, channel: String, stamp: Int64) -> String {
        "rc:\(agentId):res:\(channel):\(stamp)"
    }

    /// 3.7：流式回复（`/fs/read`）的第 `index` 个包（从 0 起）。换序、丢包、拿别的文件的块都解不开。
    public static func remoteControlPacket(agentId: String, channel: String, stamp: Int64, index: Int) -> String {
        "rc:\(agentId):res:\(channel):\(stamp):\(index)"
    }
}

/// 无填充的 base64url，与 Relay 的 `auth.ts` 同一套。
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
