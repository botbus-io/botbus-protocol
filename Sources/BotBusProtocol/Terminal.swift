import Foundation

// 「操作电脑」第二期：终端。全部在 3.7 工作区的加密预览里，不改协议版本（PROTOCOL「工作区（3.7）› 终端」）。

extension WorkspacePath {
    /// 读：列出会话（锁着也行）。
    public static let termList = "/term/list"
    /// 写：新开一个（锁着回 `locked`）。
    public static let termCreate = "/term/create"
    /// 写：结束一个（锁着回 `locked`）。
    public static let termClose = "/term/close"
    /// WebSocket：`GET /term/attach?id=<会话>&cn=<手机随机数>`，之后全是密封的二进制消息。
    public static let termAttach = "/term/attach"
}

public enum TerminalLimits {
    /// 每台电脑最多同时几个活着的会话（已退出的不占名额）。
    public static let maxSessions = 8
    /// 每个会话留多少最近的输出，attach 时先回放。
    public static let replayBytes = 256 * 1024
    /// 一条输出消息（回放与实时）的负载上限：密封、加隧道头之后远小于 `wsmsg` 的 256 KiB。
    public static let maxOutputChunk = 64 * 1024
    /// 手机一条输入消息的负载上限（粘贴大段文字时手机自己切）。
    public static let maxInputChunk = 16 * 1024
    /// 行、列的合法范围。
    public static let sizeRange: ClosedRange<Int> = 1...1000
    /// 没人连着多久回收（秒）。
    public static let idleReap: TimeInterval = 24 * 60 * 60
}

/// 电脑先关一条终端 WebSocket 时用的关闭码（明文，只当提示：要紧的结论手机用 `/term/list` 核实）。
public enum TerminalCloseCode {
    /// 会话被关、shell 退出（之前已经发过「退出」）。
    public static let normal = 1000
    /// 收到了文本消息。
    public static let unsupportedData = 1003
    /// 解不开、序号或方向不对、电脑换了钥匙。
    public static let violation = 1008
    /// 电脑这边出错。
    public static let internalError = 1011
    /// 手机收得太慢（排队超过 1 MiB）：重连拿回放。
    public static let slowConsumer = 4008
    /// 没有这个会话。
    public static let sessionGone = 4404
    /// 这个会话的连接满了（同时最多 4 条）：手机停下、不自动重连，提示用户关掉别处的再点「重试」。
    public static let tooManyConnections = 4429
}

public struct TerminalSessionInfo: Codable, Hashable, Sendable, Identifiable {
    public struct Exit: Codable, Hashable, Sendable {
        public var code: Int32
        public init(code: Int32) { self.code = code }
    }

    public var id: String
    /// shell 的名字（`zsh`）；手机拼成「zsh · 目录名」。
    public var title: String
    /// 开的时候的工作目录（不跟着 `cd` 变）。
    public var cwd: String
    public var cols: Int
    public var rows: Int
    /// 毫秒时间戳（同 `WorkspaceStatus.armedUntil`）。
    public var createdAt: Int64
    /// shell 退出了：会话留在列表里，直到手机关掉或 24 小时后回收。
    public var exited: Exit?

    public init(id: String, title: String, cwd: String, cols: Int, rows: Int, createdAt: Int64, exited: Exit? = nil) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.createdAt = createdAt
        self.exited = exited
    }
}

/// `/term/list` 的回复。
public struct TerminalList: Codable, Hashable, Sendable {
    public var sessions: [TerminalSessionInfo]
    public init(sessions: [TerminalSessionInfo]) { self.sessions = sessions }
}

/// `/term/create` 的回复。
public struct TerminalCreated: Codable, Hashable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

extension WorkspaceRequest {
    public struct TermCreate: Codable, Hashable, Sendable {
        public var cwd: String
        public var cols: Int
        public var rows: Int
        public init(cwd: String, cols: Int, rows: Int) {
            self.cwd = cwd
            self.cols = cols
            self.rows = rows
        }
    }

    public struct TermClose: Codable, Hashable, Sendable {
        public var id: String
        public init(id: String) { self.id = id }
    }
}

// MARK: - 消息

public enum TerminalDirection: String, Sendable {
    case computerToPhone = "m2c"
    case phoneToComputer = "c2m"
}

/// 一条终端消息（解开之后）。线上明文是 `[u8 类型][u64 大端序号][负载]`。
public enum TerminalMessage: Hashable, Sendable {
    /// 0，电脑→手机，只在第一条：电脑的 16 字节随机数 `sn`。
    case hello(serverNonce: Data)
    /// 1，电脑→手机：shell 的输出（含回放）。
    case output(Data)
    /// 2，手机→电脑：键盘输入。
    case input(Data)
    /// 3，手机→电脑：新的行列。
    case resize(cols: UInt16, rows: UInt16)
    /// 4，电脑→手机：shell 退出了。
    case exit(code: Int32)
    /// 5，电脑→手机：锁的状态（锁着时输入被丢掉，电脑回一条 `armed: false`）。
    case lock(armed: Bool)
    /// 6，电脑→手机：回放发完了，之后是实时输出。
    case replayEnd

    public var kind: UInt8 {
        switch self {
        case .hello: 0
        case .output: 1
        case .input: 2
        case .resize: 3
        case .exit: 4
        case .lock: 5
        case .replayEnd: 6
        }
    }

    public var direction: TerminalDirection {
        switch self {
        case .input, .resize: .phoneToComputer
        default: .computerToPhone
        }
    }

    public var payload: Data {
        switch self {
        case .hello(let nonce): return nonce
        case .output(let bytes), .input(let bytes): return bytes
        case .resize(let cols, let rows): return Self.bigEndian(UInt32(cols) << 16 | UInt32(rows))
        case .exit(let code): return Self.bigEndian(UInt32(bitPattern: code))
        case .lock(let armed): return Data([armed ? 1 : 0])
        case .replayEnd: return Data()
        }
    }

    public static func decode(kind: UInt8, payload: Data) throws -> TerminalMessage {
        let bytes = Array(payload)
        switch kind {
        case 0:
            guard bytes.count == TerminalCipher.nonceBytes else { throw TerminalWireError.malformed }
            return .hello(serverNonce: Data(bytes))
        case 1: return .output(Data(bytes))
        case 2: return .input(Data(bytes))
        case 3:
            guard bytes.count == 4 else { throw TerminalWireError.malformed }
            return .resize(cols: UInt16(bytes[0]) << 8 | UInt16(bytes[1]), rows: UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        case 4:
            guard bytes.count == 4 else { throw TerminalWireError.malformed }
            return .exit(code: Int32(bitPattern: bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
        case 5:
            guard bytes.count == 1, bytes[0] <= 1 else { throw TerminalWireError.malformed }
            return .lock(armed: bytes[0] == 1)
        case 6:
            guard bytes.isEmpty else { throw TerminalWireError.malformed }
            return .replayEnd
        default:
            throw TerminalWireError.malformed
        }
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}

public enum TerminalWireError: Error, Equatable, Sendable {
    /// 会话号或手机随机数不是规范的 16 字节 base64url。
    case badToken
    /// 握手之前不能收发（或这一方不该做这件事）。
    case notReady
    /// 解不开：钥匙、会话、随机数、方向对不上，或者被改过。
    case cannotOpen
    /// 明文的形状不对。
    case malformed
    /// 序号不是下一个。
    case outOfOrder(expected: UInt64, got: UInt64)
    /// 这个方向不该有这种消息（或握手出现在握手之后）。
    case wrongDirection(UInt8)
}

/// 明文的拼法：`[u8 类型][u64 大端序号][负载]`。
public enum TerminalFrame {
    public static func plaintext(_ message: TerminalMessage, seq: UInt64) -> Data {
        var bytes = Data([message.kind])
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(seq >> UInt64(shift) & 0xFF)) }
        bytes.append(message.payload)
        return bytes
    }

    public static func parse(_ plaintext: Data) throws -> (kind: UInt8, seq: UInt64, payload: Data) {
        let bytes = Array(plaintext)
        guard bytes.count >= 9 else { throw TerminalWireError.malformed }
        let seq = bytes[1...8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (bytes[0], seq, Data(bytes[9...]))
    }
}

extension SealingContext {
    /// 终端握手（类型 0）：钉在这台电脑、这个会话、手机这一次的随机数上。
    public static func terminalHello(agentId: String, sessionId: String, clientNonce: String) -> String {
        "rc:\(agentId):term:\(sessionId):\(clientNonce):hello"
    }

    /// 握手之后的消息：再钉上电脑的随机数与方向，序号在明文里。
    public static func terminal(agentId: String, sessionId: String, clientNonce: String, serverNonce: String,
                                direction: TerminalDirection) -> String {
        "rc:\(agentId):term:\(sessionId):\(clientNonce):\(serverNonce):\(direction.rawValue)"
    }
}

/// 一条终端连接一端的加解密：两边各出一半随机数（手机的 `cn` 在 attach 的 query 里，电脑的 `sn` 在握手里），
/// 每个方向的序号从 0 起严格加一。Relay 把旧连接里的输入原样灌进新连接解不开（`sn` 变了），丢、换序、重放都看得出来。
/// 电脑（`AgentCore` 的 `TerminalAttachment`）与手机（ClientCore 的 `TerminalLink`、演示终端）共用这一份。
public struct TerminalCipher: Sendable {
    public enum Role: Sendable { case computer, phone }

    public static let nonceBytes = 16

    public let agentId: String
    public let sessionId: String
    public let clientNonce: String
    public let role: Role
    /// 电脑的那一半（base64url）；握手之前是 nil。
    public private(set) var serverNonce: String?
    private let sealer: Sealer
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    /// `key` 是 `K_rc`。`nonce` 只给样本注入（生产一律随机）。
    public init(key: Data, agentId: String, sessionId: String, clientNonce: String, role: Role,
                nonce: @escaping Sealer.NonceProvider = Sealer.randomNonce) throws {
        guard Self.isValidToken(sessionId), Self.isValidToken(clientNonce) else { throw TerminalWireError.badToken }
        self.sealer = try Sealer(key: key, nonce: nonce)
        self.agentId = agentId
        self.sessionId = sessionId
        self.clientNonce = clientNonce
        self.role = role
    }

    /// 会话号与手机随机数：16 个随机字节的规范 base64url（同通道号，要逐字拼进 AAD）。
    public static func newToken() -> String { WorkspaceEnvelope.newChannel() }
    public static func isValidToken(_ token: String) -> Bool { WorkspaceEnvelope.isValidChannel(token) }

    private var helloAAD: String {
        SealingContext.terminalHello(agentId: agentId, sessionId: sessionId, clientNonce: clientNonce)
    }

    private func aad(_ direction: TerminalDirection, _ serverNonce: String) -> String {
        SealingContext.terminal(agentId: agentId, sessionId: sessionId, clientNonce: clientNonce,
                                serverNonce: serverNonce, direction: direction)
    }

    private var outgoing: TerminalDirection { role == .computer ? .computerToPhone : .phoneToComputer }
    private var incoming: TerminalDirection { role == .computer ? .phoneToComputer : .computerToPhone }

    /// 电脑：定下 `sn`（缺省随机），封第一条消息「握手」（序号 0，不计入之后的序号）。
    public mutating func sealHello(serverNonce bytes: Data? = nil) throws -> Data {
        guard role == .computer, serverNonce == nil else { throw TerminalWireError.notReady }
        var generator = SystemRandomNumberGenerator()
        let nonce = bytes ?? Data((0..<Self.nonceBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        guard nonce.count == Self.nonceBytes else { throw TerminalWireError.malformed }
        let packet = try sealer.sealRaw(TerminalFrame.plaintext(.hello(serverNonce: nonce), seq: 0), aad: helloAAD)
        serverNonce = Base64URL.encode(nonce)
        return packet
    }

    /// 手机：解开握手、记下 `sn`。之后的消息才解得开、封得出。
    public mutating func openHello(_ packet: Data) throws {
        guard role == .phone, serverNonce == nil else { throw TerminalWireError.notReady }
        let plaintext: Data
        do {
            plaintext = try sealer.openRaw(packet, aad: helloAAD)
        } catch {
            throw TerminalWireError.cannotOpen
        }
        let frame = try TerminalFrame.parse(plaintext)
        guard frame.kind == 0, frame.seq == 0,
              case .hello(let nonce) = try TerminalMessage.decode(kind: 0, payload: frame.payload) else {
            throw TerminalWireError.malformed
        }
        serverNonce = Base64URL.encode(nonce)
    }

    public mutating func seal(_ message: TerminalMessage) throws -> Data {
        guard let serverNonce else { throw TerminalWireError.notReady }
        guard message.kind != 0, message.direction == outgoing else { throw TerminalWireError.wrongDirection(message.kind) }
        let packet = try sealer.sealRaw(TerminalFrame.plaintext(message, seq: sent), aad: aad(outgoing, serverNonce))
        sent += 1
        return packet
    }

    public mutating func open(_ packet: Data) throws -> TerminalMessage {
        guard let serverNonce else { throw TerminalWireError.notReady }
        let plaintext: Data
        do {
            plaintext = try sealer.openRaw(packet, aad: aad(incoming, serverNonce))
        } catch {
            throw TerminalWireError.cannotOpen
        }
        let frame = try TerminalFrame.parse(plaintext)
        guard frame.seq == received else { throw TerminalWireError.outOfOrder(expected: received, got: frame.seq) }
        let message = try TerminalMessage.decode(kind: frame.kind, payload: frame.payload)
        guard frame.kind != 0, message.direction == incoming else { throw TerminalWireError.wrongDirection(frame.kind) }
        received += 1
        return message
    }
}
