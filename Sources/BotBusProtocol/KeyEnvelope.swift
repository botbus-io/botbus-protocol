import Foundation

/// 手机 → Mac 的密钥信封（协议 3.0）：把组密钥 K 加密给一台 Mac 的临时 X25519 公钥。
///
/// Mac 每次配对 offer 生成一对临时密钥，公钥印在二维码里（`pk=`），私钥只在内存。手机扫到后：
/// 共享秘密 = X25519(手机临时私钥, Mac 公钥)，HKDF-SHA256（salt = Mac 公钥原始字节，info 见下）得 32 字节包裹键，
/// AES-256-GCM 密封 K（AAD = `key-envelope:<agentId>`）。信封随 `/pair/claim` 或 `/pair/agents` 上传，
/// Relay 存进 agents 表并在 hello 帧里带给 Mac。Relay 只见 `epk` 与密文，Mac 的公钥从未经过它，算不出共享秘密。
public struct KeyEnvelope: Codable, Hashable, Sendable {
    public static let info = "botbus/v1/key-envelope"

    /// 手机临时 X25519 公钥，base64url 32 字节。
    public var epk: String
    public var sealed: Sealed

    public init(epk: String, sealed: Sealed) {
        self.epk = epk
        self.sealed = sealed
    }

    /// 手机侧：把 K 封给 `recipient`。`ephemeral` 只给 fixture 注入固定密钥，生产环境每次新生成。
    public static func seal(_ key: PairKey, to recipient: Curve25519.KeyAgreement.PublicKey, agentId: String,
                            ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(),
                            nonce: @escaping Sealer.NonceProvider = Sealer.randomNonce) throws -> KeyEnvelope {
        let wrapping = try wrappingKey(shared: ephemeral.sharedSecretFromKeyAgreement(with: recipient), recipient: recipient)
        let sealer = try Sealer(key: wrapping, nonce: nonce)
        return KeyEnvelope(epk: Base64URL.encode(ephemeral.publicKey.rawRepresentation),
                           sealed: try sealer.seal(key.root, aad: SealingContext.keyEnvelope(agentId: agentId)))
    }

    /// Mac 侧：用配对 offer 的临时私钥解开。
    public func open(with recipientKey: Curve25519.KeyAgreement.PrivateKey, agentId: String) throws -> PairKey {
        guard let epkData = Base64URL.decode(epk),
              let sender = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: epkData) else {
            throw SealingError.malformed
        }
        let wrapping = try wrappingKey(shared: recipientKey.sharedSecretFromKeyAgreement(with: sender),
                                       recipient: recipientKey.publicKey)
        let sealer = try Sealer(key: wrapping)
        return try PairKey(root: sealer.open(sealed, aad: SealingContext.keyEnvelope(agentId: agentId)))
    }

    private static func wrappingKey(shared: SharedSecret, recipient: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                       salt: recipient.rawRepresentation,
                                       sharedInfo: Data(info.utf8),
                                       outputByteCount: PairKey.length)
            .withUnsafeBytes { Data($0) }
    }

    private func wrappingKey(shared: SharedSecret, recipient: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        try Self.wrappingKey(shared: shared, recipient: recipient)
    }
}

extension Curve25519.KeyAgreement.PublicKey {
    /// 二维码里的 `pk=` 文本。
    public var base64url: String { Base64URL.encode(rawRepresentation) }

    public init?(base64url text: String) {
        guard let data = Base64URL.decode(text), let key = try? Self(rawRepresentation: data) else { return nil }
        self = key
    }
}
