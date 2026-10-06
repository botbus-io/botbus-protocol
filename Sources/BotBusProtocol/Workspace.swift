import Foundation

/// 「操作电脑」的工作区服务（协议 3.7）在线上的类型。电脑端的 `WorkspaceEndpoints` 与手机端共用这一份，
/// Android 照它在 `android/core` 里写同样的 Kotlin。
///
/// 全部走远程操作那条加密预览：请求是 `POST {"sealed": …}`，明文是请求体的 JSON 对象并上 `p`（路径）、`t`（毫秒时间戳）、
/// `c`（通道号）；回复钉在请求上（`SealingContext.remoteControlResponse`）。Relay 只转发，看不到也不解析。
/// 契约见 PROTOCOL「六、屏幕共享与远程操作 › 工作区（3.7）」。
public enum WorkspacePath {
    public static let status = "/status"
    public static let arm = "/arm"
    public static let fsList = "/fs/list"
    public static let fsRead = "/fs/read"
    public static let fsWrite = "/fs/write"
    public static let fsMkdir = "/fs/mkdir"
    public static let fsCreate = "/fs/create"
    public static let fsRename = "/fs/rename"
    public static let fsTrash = "/fs/trash"
    public static let fsUploadBegin = "/fs/upload/begin"
    public static let fsUploadChunk = "/fs/upload/chunk"
    public static let fsUploadCommit = "/fs/upload/commit"
}

/// `WorkspaceStatus.features` 里的值。开集：不认得的值忽略。
public enum WorkspaceFeature {
    public static let files = "files"
    public static let terminal = "terminal"
    public static let screen = "screen"
    /// 屏幕服务认 `/move`（只挪指针）与 `/click` 的 `button: "right"`：手机单指按住移动就是挪鼠标。
    /// 没报的旧 Mac 上单指划动照旧是滚动。
    public static let pointer = "pointer"
}

public enum WorkspaceLimits {
    /// 能在手机上编辑的文本上限。
    public static let maxEditableBytes = 1_000_000
    /// 上传每块的上限：加密、base64 之后仍远小于隧道 16 MiB 的请求体上限。
    public static let maxUploadChunkBytes = 4 * 1024 * 1024
    /// 单个上传文件的上限。
    public static let maxUploadBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// 一个目录最多列这么多项，多了截断并标 `truncated`。
    public static let maxListEntries = 5000
}

/// `GET /status`（旧格式的 AAD，旧 Mac 也有）与 `POST /status` 的回复。屏幕那几个字段只有 Mac 有，旧查看页读它们。
public struct WorkspaceStatus: Codable, Hashable, Sendable {
    public struct Display: Codable, Hashable, Sendable {
        public var id: UInt32
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(id: UInt32, x: Int, y: Int, width: Int, height: Int) {
            self.id = id
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// 3.7 起才有：这台电脑的工作区提供什么（`WorkspaceFeature`）。旧 Mac 没有这个键，只有屏幕。
    public var features: [String]?
    public var armed: Bool
    /// 解锁时的到期时间（毫秒时间戳）；锁着时省略。
    public var armedUntil: Int64?
    /// 电脑上的主目录：文件 tab 的兜底起点、面包屑里显示成 `~`。
    public var home: String?
    /// `macos` / `linux` / `windows`（与 `AgentPlatform` 同一套值）。
    public var platform: String?
    public var accessibility: Bool?
    public var screenCapture: Bool?
    public var secureInput: Bool?
    public var streaming: Bool?
    public var frontmost: String?
    public var displays: [Display]?

    public init(features: [String]? = nil, armed: Bool, armedUntil: Int64? = nil, home: String? = nil,
                platform: String? = nil, accessibility: Bool? = nil, screenCapture: Bool? = nil,
                secureInput: Bool? = nil, streaming: Bool? = nil, frontmost: String? = nil,
                displays: [Display]? = nil) {
        self.features = features
        self.armed = armed
        self.armedUntil = armedUntil
        self.home = home
        self.platform = platform
        self.accessibility = accessibility
        self.screenCapture = screenCapture
        self.secureInput = secureInput
        self.streaming = streaming
        self.frontmost = frontmost
        self.displays = displays
    }

    /// 旧 Mac 不报 `features`：只有屏幕。
    public func supports(_ feature: String) -> Bool {
        guard let features else { return feature == WorkspaceFeature.screen }
        return features.contains(feature)
    }
}

/// 目录里的一项。
public struct WorkspaceEntry: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file, dir, other

        /// 以后的电脑可能报新的类型：一律当 `other`，不拒收整份列表。
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }
    }

    public var name: String
    /// 软链接按它指向的东西报（指向目录的能点进去）；断掉的链接是 `other`。
    public var kind: Kind
    /// 这一项本身是软链接。只写 true。
    public var link: Bool?
    /// 字节数，只有文件有。
    public var size: Int64?
    public var mtimeMs: Int64
    /// 点开头的名字。只写 true，并且只有请求了 `hidden` 才会出现。
    public var hidden: Bool?
    /// git 标记：`M` / `A` / `D` / `?` / `U`，目录在仓库里时才有；目录里有改动时目录标 `M`。
    public var git: String?
    /// 第三期：名字解不出来（Linux 上不是合法 UTF-8，Windows 上含落单的代理项）。`name` 是把解不出来的部分换成 U+FFFD
    /// 之后的，按它碰不到原来那一项；`kind` 一律 `other`。
    /// 只写 true。
    public var undecodable: Bool?

    public init(name: String, kind: Kind, link: Bool? = nil, size: Int64? = nil, mtimeMs: Int64,
                hidden: Bool? = nil, git: String? = nil, undecodable: Bool? = nil) {
        self.name = name
        self.kind = kind
        self.link = link
        self.size = size
        self.mtimeMs = mtimeMs
        self.hidden = hidden
        self.git = git
        self.undecodable = undecodable
    }
}

public struct WorkspaceListing: Codable, Hashable, Sendable {
    /// 规范化之后的目录绝对路径。
    public var path: String
    public var entries: [WorkspaceEntry]
    public var truncated: Bool?
    /// 目录在 git 仓库里时是仓库根。
    public var repoRoot: String?

    public init(path: String, entries: [WorkspaceEntry], truncated: Bool? = nil, repoRoot: String? = nil) {
        self.path = path
        self.entries = entries
        self.truncated = truncated
        self.repoRoot = repoRoot
    }
}

/// 文件的修改时间与大小：编辑保存时的冲突判据。
public struct WorkspaceFileStamp: Codable, Hashable, Sendable {
    public var mtimeMs: Int64
    public var size: Int64

    public init(mtimeMs: Int64, size: Int64) {
        self.mtimeMs = mtimeMs
        self.size = size
    }
}

/// `/fs/read` 流的第一个包。
public struct WorkspaceFileHeader: Codable, Hashable, Sendable {
    public var size: Int64
    public var mtimeMs: Int64
    public var contentType: String?

    public init(size: Int64, mtimeMs: Int64, contentType: String? = nil) {
        self.size = size
        self.mtimeMs = mtimeMs
        self.contentType = contentType
    }
}

/// `/fs/read` 流的最后一个包：总字节数。没收到它就是被截断了。
public struct WorkspaceReadEnd: Codable, Hashable, Sendable {
    public var size: Int64
    public init(size: Int64) { self.size = size }
}

/// 失败的回复（HTTP 200 + 密封的 `{"failure": …}`）。手机按 `code` 显示本地化文案。
public struct WorkspaceFailure: Codable, Hashable, Sendable, Error {
    public enum Code: String, Codable, Sendable {
        case notFound, notDirectory, exists, tooLarge, invalid, denied, tcc, timeout, locked, conflict, uploadGone
        /// 第三期：这个位置没有能用的废纸篓（Linux 找不到可用的 XDG 废纸篓、Windows 的回收站收不了、Mac 的卷不支持），
        /// 文件原样留着，没有删除。旧手机按 `failed`。
        case noTrash
        case failed

        /// 以后的电脑可能加新的 code：按 `failed` 处理。
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Code(rawValue: raw) ?? .failed
        }
    }

    public var code: Code
    /// 只给排查看的英文细节，不直接显示。
    public var detail: String?
    /// `conflict` 时电脑上文件现在的样子。
    public var current: WorkspaceFileStamp?

    public init(_ code: Code, detail: String? = nil, current: WorkspaceFileStamp? = nil) {
        self.code = code
        self.detail = detail
        self.current = current
    }
}

/// 回复的外形：成功是结果对象本身，失败是 `{"failure": …}`。
public enum WorkspaceReply {
    private struct FailureBox: Encodable {
        var failure: WorkspaceFailure
    }

    /// 只看顶层有没有 `failure` 键：有就是失败，哪怕里面的内容坏了（坏掉的失败不能被当成成功）。
    private struct FailureProbe: Decodable {
        private enum Keys: String, CodingKey { case failure }

        /// 顶层对象没有 `failure` 键时为 nil。
        let failure: WorkspaceFailure?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            guard container.contains(.failure) else {
                failure = nil
                return
            }
            failure = (try? container.decode(WorkspaceFailure.self, forKey: .failure))
                ?? WorkspaceFailure(.failed, detail: "malformed failure")
        }
    }

    public static func encodeFailure(_ failure: WorkspaceFailure) -> Data {
        (try? JSONEncoder().encode(FailureBox(failure: failure))) ?? Data(#"{"failure":{"code":"failed"}}"#.utf8)
    }

    /// 顶层有 `failure` 键就抛 `WorkspaceFailure`（内容解不开时抛 `.failed`，detail 为 `malformed failure`），
    /// 否则按成功类型解；顶层不是对象时探测失败，直接交给成功类型去报错。
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if let probe = try? JSONDecoder().decode(FailureProbe.self, from: data), let failure = probe.failure {
            throw failure
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

/// 各端点的请求体（明文里还会并上 `p`、`t`、`c`）。
public enum WorkspaceRequest {
    public struct List: Codable, Hashable, Sendable {
        public var path: String
        public var hidden: Bool?
        public init(path: String, hidden: Bool? = nil) {
            self.path = path
            self.hidden = hidden
        }
    }

    /// `/fs/read`、`/fs/mkdir`、`/fs/create`、`/fs/trash`。
    public struct Target: Codable, Hashable, Sendable {
        public var path: String
        public init(path: String) { self.path = path }
    }

    public struct Write: Codable, Hashable, Sendable {
        public var path: String
        /// 文件内容的 base64（标准字母表）。
        public var content: String
        public var expect: WorkspaceFileStamp?
        public init(path: String, content: String, expect: WorkspaceFileStamp? = nil) {
            self.path = path
            self.content = content
            self.expect = expect
        }
    }

    public struct Rename: Codable, Hashable, Sendable {
        public var from: String
        public var to: String
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public struct UploadBegin: Codable, Hashable, Sendable {
        public var dir: String
        public var name: String
        public var size: Int64
        public init(dir: String, name: String, size: Int64) {
            self.dir = dir
            self.name = name
            self.size = size
        }
    }

    public struct UploadChunk: Codable, Hashable, Sendable {
        public var uploadId: String
        public var offset: Int64
        /// 这一块的 base64（标准字母表），解出来 ≤ `WorkspaceLimits.maxUploadChunkBytes`。
        public var bytes: String
        public init(uploadId: String, offset: Int64, bytes: String) {
            self.uploadId = uploadId
            self.offset = offset
            self.bytes = bytes
        }
    }

    public struct UploadCommit: Codable, Hashable, Sendable {
        public var uploadId: String
        public init(uploadId: String) { self.uploadId = uploadId }
    }

    public struct Arm: Codable, Hashable, Sendable {
        public var on: Bool
        public init(on: Bool) { self.on = on }
    }
}

public struct WorkspaceUploadStarted: Codable, Hashable, Sendable {
    public var uploadId: String
    public init(uploadId: String) { self.uploadId = uploadId }
}

public struct WorkspaceUploadProgress: Codable, Hashable, Sendable {
    public var received: Int64
    public init(received: Int64) { self.received = received }
}

public struct WorkspaceCommitted: Codable, Hashable, Sendable {
    /// 落下来的绝对路径（同名时自动改成「名字 2.扩展名」）。
    public var path: String
    public init(path: String) { self.path = path }
}

/// 没有内容的成功回复：`{}`。解码时要求顶层是对象（`[]`、`null`、数字都不是合法的空回复），里面有什么键不管。
public struct WorkspaceEmpty: Codable, Hashable, Sendable {
    private enum NoKeys: CodingKey {}

    public init() {}

    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: NoKeys.self)
    }

    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: NoKeys.self)
    }
}

/// 请求明文的拼法与通道号。
public enum WorkspaceEnvelope {
    public static let channelBytes = 16

    /// 请求体不能自带的键：`p`（路径）、`t`（时间戳）、`c`（通道号）由信封并上去。
    private static let reservedKeys: Set<String> = ["p", "t", "c"]

    /// 手机每次打开页面生成一个：16 个随机字节的 base64url（22 个字符）。
    public static func newChannel() -> String {
        var generator = SystemRandomNumberGenerator()
        return Base64URL.encode(Data((0..<channelBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    /// 规范的 base64url：恰好 22 个字符、都在字母表 `[A-Za-z0-9_-]` 里、最后一个字符多出来的低位是 0（只有 `A` `Q` `g` `w`），
    /// 并且解出来正好 16 个字节。`+` `/`、填充和别的写法都不要——通道号要逐字拼进 AAD，两端必须对同一个串。
    public static func isValidChannel(_ channel: String) -> Bool {
        let length = (channelBytes * 8 + 5) / 6
        let characters = Array(channel.utf8)
        guard characters.count == length else { return false }
        var lastValue = 0
        for byte in characters {
            guard let value = base64URLValue(byte) else { return false }
            lastValue = value
        }
        let unusedBits = length * 6 - channelBytes * 8
        guard lastValue & ((1 << unusedBits) - 1) == 0 else { return false }
        return Base64URL.decode(channel)?.count == channelBytes
    }

    /// base64url 字母表里这个字符代表的 6 位值；不在字母表里是 nil。
    private static func base64URLValue(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return Int(byte - UInt8(ascii: "A"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return Int(byte - UInt8(ascii: "a")) + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(byte - UInt8(ascii: "0")) + 52
        case UInt8(ascii: "-"): return 62
        case UInt8(ascii: "_"): return 63
        default: return nil
        }
    }

    /// 明文 = 请求体的 JSON 对象并上 `p`、`t`（与可选的 `c`）。输出是键排序、斜杠不转义的规范 JSON，
    /// 在当前的键集下（都是小写字母开头、不含数字）与 `scripts/seal-fixtures.mjs` 的 `canonical()` 逐字节相同，
    /// 样本和测试可以直接比字节。`JSONSerialization` 的 `.sortedKeys` 不分大小写、按数值排数字，
    /// 和 JS 的码位排序不同，加键时留意。
    /// 请求体自己带 `p` / `t` / `c` 会盖掉路径、时间戳或通道号，所以直接抛 `SealingError.mismatch`。
    public static func plaintext<T: Encodable>(_ body: T, path: String, stamp: Int64, channel: String?) throws -> Data {
        let encoded = try JSONEncoder().encode(body)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw SealingError.malformed
        }
        guard reservedKeys.isDisjoint(with: object.keys) else {
            throw SealingError.mismatch("request body uses reserved key p/t/c")
        }
        object["p"] = path
        object["t"] = stamp
        if let channel { object["c"] = channel }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// 流式回复的包：线上是 `[u32 大端长度][密封后的原始字节]`，明文是 `[u8 类型][负载]`。
public enum WorkspacePacket {
    public enum Kind: UInt8, Sendable {
        /// `WorkspaceFileHeader` 的 JSON。
        case header = 0
        /// 文件字节。
        case data = 1
        /// `WorkspaceReadEnd` 的 JSON。
        case end = 2
    }

    /// 读文件时每块多大。
    public static let dataChunkBytes = 256 * 1024
    /// 解析时一包密文的上限：防着坏数据让缓冲区无限长。只管工作区的流（`/fs/read`），
    /// 屏幕共享的 `/stream` 是另一套分帧，不受它限制。
    public static let maxSealedBytes = 1 << 20

    public static func plaintext(_ kind: Kind, _ payload: Data) -> Data {
        var bytes = Data([kind.rawValue])
        bytes.append(payload)
        return bytes
    }

    public static func frame(_ sealed: Data) -> Data {
        assert(sealed.count <= maxSealedBytes, "一包密文不能超过 maxSealedBytes，对端的 drain 会拒收")
        var length = UInt32(sealed.count).bigEndian
        var framed = Data()
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(sealed)
        return framed
    }

    /// 从缓冲区切出完整的包（密封后的原始字节），不完整的留在 `buffer` 里。长度越界（0 或超过 `maxSealedBytes`）
    /// 抛 `SealingError.malformed`：抛出之后这条流已经没法再对齐，也拿不回这次已切出的包，调用方必须整条丢掉。
    public static func drain(_ buffer: inout Data) throws -> [Data] {
        var packets: [Data] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 4 {
            let length = buffer[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= maxSealedBytes else { throw SealingError.malformed }
            guard buffer.endIndex - offset - 4 >= length else { break }
            packets.append(Data(buffer[(offset + 4)..<(offset + 4 + length)]))
            offset += 4 + length
        }
        buffer = Data(buffer[offset...])
        return packets
    }
}
