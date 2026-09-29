import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// hook 服务器的共享密钥：只绑 127.0.0.1 挡不住同一台机器上的**别的用户**（Linux 多用户服务器上人人都能连回环），
/// 所以每次 `start()` 生成一个随机密钥，写进支持目录里只有本用户可读的文件（0600），
/// hook 脚本读它、在请求头 `X-BotBus-Hook-Secret` 里带回来；不对的请求一律 403。
///
/// 按实例开关（`LocalHookServer(sharedSecret:)`）：只有 Claude hook 服务器开。工具服务器（`LocalToolAPI`）
/// 已经按 task token 鉴权，Codex 桌面桥走的是自己的通道，都不传。
///
/// 文件内容是一行 curl 配置（`header = "X-BotBus-Hook-Secret: …"`），脚本用 `curl --config` 读：
/// 密钥不能放命令行参数，Linux 上别的用户 `ps` 就能看到 argv。
extension LocalHookServer {
    public struct SharedSecret: Sendable, Equatable {
        public enum Enforcement: Sendable, Equatable {
            /// 没带、带错都拒绝。
            case required
            /// 带了就必须对；没带放行。只给 macOS 兼容老 hook 脚本用（升级前装的脚本不发这个头）。
            case whenPresent
        }

        public static let headerName = "X-BotBus-Hook-Secret"
        /// hook 脚本写死了读这个文件名（和端口文件在同一个目录）。
        public static let defaultFileName = "agent-secret.curlrc"

        public var fileName: String
        public var enforcement: Enforcement

        public init(fileName: String = SharedSecret.defaultFileName, enforcement: Enforcement) {
            self.fileName = fileName
            self.enforcement = enforcement
        }

        /// Linux 必须带（多用户机器）；macOS 带错拒绝、不带放行——已经装在用户机器上的老脚本不发这个头，
        /// 要等 `ClaudeHookInstaller.upgradeIfNeeded` 把脚本换掉才会发。
        public static var platformDefault: SharedSecret {
            #if canImport(Darwin)
            return SharedSecret(enforcement: .whenPresent)
            #else
            return SharedSecret(enforcement: .required)
            #endif
        }
    }

    /// 密钥文件的位置。没开密钥的实例是 nil。
    public nonisolated var secretFileURL: URL? {
        sharedSecret.map { supportDirectory.appendingPathComponent($0.fileName) }
    }

    /// 32 字节随机数的十六进制。`SystemRandomNumberGenerator` 在各平台都取系统的密码学随机源。
    static func makeSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        var text = ""
        for _ in 0..<32 {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return text
    }

    /// 换一个新密钥。在监听之前调：第一条连接进来时必须已经有值。
    func rotateSecret() {
        activeSecret = sharedSecret == nil ? nil : Self.makeSecret()
    }

    /// 请求有没有资格交给 handler。返回 nil = 放行；否则是要回的拒绝。
    ///
    /// 拒绝是 **403 空 body**：老版本脚本（没有 `curl -f`）会把响应 body 原样吐给 Claude Code，
    /// 空 body 才不会被当成 hook 输出。
    func rejection(for request: Request) -> Response? {
        guard let sharedSecret else { return nil }
        guard let presented = request.header(SharedSecret.headerName) else {
            return sharedSecret.enforcement == .required ? Self.forbidden : nil
        }
        // 没开出密钥（理论上不会：start() 里先换密钥再监听）就什么都不认。
        guard let activeSecret, Self.constantTimeEquals(presented, activeSecret) else {
            Self.log.warning("hook 请求的密钥不对，已拒绝")
            return Self.forbidden
        }
        return nil
    }

    static let forbidden = Response(status: 403)

    /// 逐字节异或累加，比较时间与第一个不同字节的位置无关。长度不同直接返回（密钥长度是公开的 64）。
    nonisolated static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// 端口就绪后调：先写密钥，再写端口文件——脚本看到端口文件时密钥一定已经在了。
    func publish(port: UInt16) {
        writeSecretFile()
        writePortFile(port)
    }

    /// stop() 时删密钥文件并作废内存里的密钥。
    func retractSecret() {
        activeSecret = nil
        if let secretFileURL { try? FileManager.default.removeItem(at: secretFileURL) }
    }

    private func writeSecretFile() {
        guard let secretFileURL, let activeSecret else { return }
        do {
            try Self.prepareSupportDirectory(supportDirectory)
            let line = "header = \"\(SharedSecret.headerName): \(activeSecret)\"\n"
            try Self.writePrivateFile(Data(line.utf8), to: secretFileURL)
        } catch {
            // 写不出来：Linux 上的 hook 会全被 403（宁可收不到，也不放行）；macOS 上老脚本照常。
            Self.log.error("写 hook 密钥文件失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 建好支持目录。Linux 上顺手收紧到 0700：里面有密钥、端口和各种存档，多用户机器上别人不该列得出来。
    /// macOS 的 `~/Library` 本来就是 0700，不去动 `Application Support/BotBus` 的权限。
    static func prepareSupportDirectory(_ directory: URL) throws {
        #if canImport(Darwin)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
        #endif
    }

    /// 原子写一个 0600 的文件：临时文件一创建就是 0600（`O_EXCL | O_NOFOLLOW`，不经过默认 umask 的窗口），
    /// 写完 rename 过去。rename 替换的是目录项本身，目标是符号链接也不会顺着写到别处。
    static func writePrivateFile(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)").path
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        // umask 只会去掉位，不会加；这里再钉一次，防止继承了奇怪的 ACL 默认值。
        if failure == 0, fchmod(descriptor, 0o600) != 0 { failure = errno }
        close(descriptor)
        if failure == 0, rename(temporary, url.path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temporary)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }
}
