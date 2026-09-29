import Foundation

/// `POST /agent/register` 的响应。此时还没有 Pair，Agent 只拿到自己的身份与一个待认领的码。
public struct AgentRegisterResponse: Codable, Hashable, Sendable {
    public var agentId: String
    public var agentToken: String
    public var code: String
    public var expiresAt: String
    public init(agentId: String, agentToken: String, code: String, expiresAt: String) {
        self.agentId = agentId
        self.agentToken = agentToken
        self.code = code
        self.expiresAt = expiresAt
    }
}

/// `POST /pair/claim` 与 `POST /pair/agents` 的请求体。
///
/// - `sealedName`：手机名，用 `K_content` 密封（AAD `client`），只有认领时才有意义；Relay 存密文，`/pair/clients` 原样回。
/// - `keyEnvelope`：把组密钥封给目标 Mac（协议 3.0，`KeyEnvelope`）。用注册码认领（新组，手机刚生成 K）
///   与 `/pair/agents`（加第二台电脑）时必填；用邀请码认领时省略——K 在 Mac 印的二维码里。
public struct PairClaimRequest: Codable, Hashable, Sendable {
    public var code: String
    public var sealedName: Sealed?
    public var keyEnvelope: KeyEnvelope?
    public init(code: String, sealedName: Sealed? = nil, keyEnvelope: KeyEnvelope? = nil) {
        self.code = code
        self.sealedName = sealedName
        self.keyEnvelope = keyEnvelope
    }
}

public struct PairClaimResponse: Codable, Hashable, Sendable {
    public var pairId: String
    public var clientToken: String
    /// 这台手机现在能看到的全部电脑。用注册码建组时只有刚认领的那一台（尚未连上，
    /// 因此 `online` 为 false、`sealed` 为空）；用邀请码加入已有组时是组里的全部。
    public var agents: [SealedAgent]
    public init(pairId: String, clientToken: String, agents: [SealedAgent]) {
        self.pairId = pairId
        self.clientToken = clientToken
        self.agents = agents
    }
}

/// `POST /pair/agents` 的响应：新加入本 Pair 的那台电脑。
public struct PairAgentsResponse: Codable, Hashable, Sendable {
    public var agent: SealedAgent
    public init(agent: SealedAgent) { self.agent = agent }
}

/// `POST /agent/invite` 的响应：电脑替本组印的手机邀请码，供第二台手机扫。
/// 注意它不含任何凭据——扫码的那台手机换到的 `clientToken` 由 `/pair/claim` 发。
public struct AgentInviteResponse: Codable, Hashable, Sendable {
    public var code: String
    public var expiresAt: String
    public init(code: String, expiresAt: String) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

/// `GET /pair/clients` 的响应：本组的手机，不含任何 token。
public struct PairClientsResponse: Codable, Hashable, Sendable {
    public struct Client: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        /// 手机名的密文（`K_content`，AAD `client`）；协议 v2 时代的记录没有名字，此时省略。
        public var sealedName: Sealed?
        public var addedAt: String
        /// 是不是发起这次请求的那一台。踢自己下线要额外确认，界面靠它区分。
        public var current: Bool
        public init(id: String, sealedName: Sealed?, addedAt: String, current: Bool) {
            self.id = id
            self.sealedName = sealedName
            self.addedAt = addedAt
            self.current = current
        }
    }

    public var clients: [Client]
    public init(clients: [Client]) { self.clients = clients }
}

/// `GET /agent/devices` 的响应：本 Pair 下的手机与手表，不含任何 token。
///
/// `devices` 是推送注册（手机、手表各一条，带最后活跃时间）；`clients`（2.15）是本组的手机凭据，
/// 电脑拿 `id` 调 `DELETE /pair/clients/:id` 移除一台手机。手表沿用配它的那台手机的凭据，
/// 所以它的 `clientId` 和那台手机相同。
public struct AgentDevicesResponse: Codable, Hashable, Sendable {
    public struct Device: Codable, Hashable, Sendable {
        /// 设备名的密文（`K_content`，AAD `client`，3.0）：由那台手机 / 手表自己封，Relay 读不到。
        public var sealedName: Sealed
        public var platform: DeviceRegistration.Platform
        public var lastSeenAt: String
        /// 2.15：注册这条推送的那份手机凭据。2.15 之前注册、还没重新上报过的设备没有。
        public var clientId: String?
        public init(sealedName: Sealed, platform: DeviceRegistration.Platform, lastSeenAt: String, clientId: String? = nil) {
            self.sealedName = sealedName
            self.platform = platform
            self.lastSeenAt = lastSeenAt
            self.clientId = clientId
        }
    }

    /// 本组的一台手机（一份 clientToken）。`id` 只是移除用的把手，不是凭据。
    public struct Client: Codable, Hashable, Sendable {
        public var id: String
        /// 手机名的密文（同 `PairClientsResponse.Client.sealedName`）；v2 时代的记录没有。
        public var sealedName: Sealed?
        public var addedAt: String
        public init(id: String, sealedName: Sealed?, addedAt: String) {
            self.id = id
            self.sealedName = sealedName
            self.addedAt = addedAt
        }
    }

    public var devices: [Device]
    /// 2.15。
    public var clients: [Client]
    public init(devices: [Device], clients: [Client] = []) {
        self.devices = devices
        self.clients = clients
    }
}

/// `POST /client/devices` 的请求体：一条推送注册。
///
/// 3.0 起设备名是密文（`K_content`，AAD `client`），客户端先截到 40 字再封；Relay 只存、只转交给电脑。
/// 注意 `lastSeenAt` 不在请求体里：它由 Relay 维护，只出现在 `/agent/devices` 的响应中。
public struct DeviceRegistration: Codable, Hashable, Sendable {
    public enum Platform: String, Codable, Sendable, CaseIterable { case ios, watchos, android }
    public enum PushEnvironment: String, Codable, Sendable, CaseIterable { case sandbox, production }

    /// 名字的长度上限（字符），封之前截断。
    public static let maxNameLength = 40

    public var token: String
    public var platform: Platform
    public var environment: PushEnvironment
    public var sealedName: Sealed
    public init(token: String, platform: Platform, environment: PushEnvironment, sealedName: Sealed) {
        self.token = token
        self.platform = platform
        self.environment = environment
        self.sealedName = sealedName
    }
}

public struct CommandAccepted: Codable, Hashable, Sendable {
    public var commandId: String
    public var delivered: Bool
    public init(commandId: String, delivered: Bool) {
        self.commandId = commandId
        self.delivered = delivered
    }
}

/// `PUT /agent/artifacts/:artifactId` 的响应：Relay 存下的产物字节数与到期时间。
public struct ArtifactUploadResponse: Codable, Hashable, Sendable {
    public var id: String
    public var size: Int
    public var expiresAt: String
    public init(id: String, size: Int, expiresAt: String) {
        self.id = id
        self.size = size
        self.expiresAt = expiresAt
    }
}

/// `POST /agent/previews` 的请求体。
public struct PreviewCreateRequest: Codable, Hashable, Sendable {
    public var title: String?
    public init(title: String? = nil) { self.title = title }
}

/// `POST /agent/previews` 的响应。`previewId` 是 26 字符小写 base32，预览主机为 `p-<previewId>.<预览域名>`。
public struct PreviewCreateResponse: Codable, Hashable, Sendable {
    public var previewId: String
    public var expiresAt: String
    public init(previewId: String, expiresAt: String) {
        self.previewId = previewId
        self.expiresAt = expiresAt
    }
}

/// `POST /client/previews/:previewId/session` 的响应。
/// `url` 是带一次性 ticket 的完整预览入口（`https://p-<id>.<预览域名>/__botbus/auth?ticket=…`），
/// `expiresAt` 是这个 ticket 的失效时间（签发后 60 秒）——url 只能打开一次，每次打开都要重新取。
public struct PreviewSessionResponse: Codable, Hashable, Sendable {
    public var url: String
    public var expiresAt: String
    public init(url: String, expiresAt: String) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

/// Agent → Relay 的 WebSocket 帧。协议 3.0 起帧里是密封形状。
public struct AgentFrame: Codable, Hashable, Sendable {
    public enum FrameType: String, Codable, Sendable { case event }
    public var type: FrameType
    public var event: SealedEvent
    public init(event: SealedEvent) {
        self.type = .event
        self.event = event
    }
}

/// Agent → Relay 的 WebSocket 帧：确认收到命令。
///
/// Agent 解密并派发命令后立即发 ack，不等执行完成。Relay 收到后从队列移除该命令。
public struct RelayAckFrame: Codable, Hashable, Sendable {
    public enum FrameType: String, Codable, Sendable { case ack }
    public var type: FrameType
    public var commandIds: [String]
    public init(commandIds: [String]) {
        self.type = .ack
        self.commandIds = commandIds
    }
}

/// Relay → Agent 的 WebSocket 帧。
public struct RelayFrame: Codable, Hashable, Sendable {
    public enum FrameType: String, Codable, Sendable { case command }
    public var type: FrameType
    public var command: SealedCommand
    public init(command: SealedCommand) {
        self.type = .command
        self.command = command
    }
}

/// Relay → Agent 的 WebSocket 帧：每次连上后 Relay 先告诉这台电脑它属于哪个组。
///
/// Agent 记下 `pairId`，下次连接带上 `X-Pair-Hint`，Relay 就能跳过全局 Directory 直接找到组。
/// 它只是路由提示，不是凭据：agentToken 仍由那个组的 PairObject 核对，提示不对时 Relay 回落到 Directory。
/// 旧版 Agent 把它当成解不开的 `RelayFrame` 忽略掉。
public struct RelayHelloFrame: Codable, Hashable, Sendable {
    public enum FrameType: String, Codable, Sendable { case hello }
    public var type: FrameType
    public var pairId: String
    /// 协议 3.0：手机封给这台 Mac 的组密钥（`KeyEnvelope`），Relay 从 agents 表里带出。
    /// 已经持有 K 的 Mac 忽略它；Relay 在每次 hello 里都带，直到这条记录被清掉（组解散）。
    public var keyEnvelope: KeyEnvelope?
    public init(pairId: String, keyEnvelope: KeyEnvelope? = nil) {
        self.type = .hello
        self.pairId = pairId
        self.keyEnvelope = keyEnvelope
    }
}

/// Relay → 客户端的 WebSocket 帧（`GET /client/ws`）。
///
/// - `snapshot`：一份全量快照，和 `GET /client/snapshot` 的 200 响应体一样；
/// - `changed`：快照变了，但这一份太大不适合走 WebSocket，客户端应改用 `GET /client/snapshot?since=-1` 取全量。
///
/// 与 `Event` 相同：与 `type` 配套的字段必须存在，否则解码失败；其余字段以 `type` 为准被忽略。
public struct ClientFrame: Codable, Hashable, Sendable {
    public enum FrameType: String, Codable, Sendable, CaseIterable { case snapshot, changed }

    public var type: FrameType
    public var snapshot: SealedSnapshot?
    public var seq: Int?

    public init(snapshot: SealedSnapshot) {
        self.type = .snapshot
        self.snapshot = snapshot
        self.seq = nil
    }

    public init(changedTo seq: Int) {
        self.type = .changed
        self.snapshot = nil
        self.seq = seq
    }

    private enum CodingKeys: String, CodingKey { case type, snapshot, seq }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(FrameType.self, forKey: .type)
        snapshot = try container.decodeIfPresent(SealedSnapshot.self, forKey: .snapshot)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        switch type {
        case .snapshot:
            guard snapshot != nil else {
                throw DecodingError.dataCorruptedError(forKey: .snapshot, in: container,
                                                       debugDescription: "payload for type snapshot is missing")
            }
            seq = nil
        case .changed:
            guard seq != nil else {
                throw DecodingError.dataCorruptedError(forKey: .seq, in: container,
                                                       debugDescription: "payload for type changed is missing")
            }
            snapshot = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch type {
        case .snapshot: try container.encode(snapshot, forKey: .snapshot)
        case .changed: try container.encode(seq, forKey: .seq)
        }
    }
}
