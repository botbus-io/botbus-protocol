import Foundation
import BotBusProtocol

/// 本机作为一台 Agent 的身份：`agentId` 来自 `POST /agent/register`，名字与版本号只是展示用。
///
/// 独立于 `RelayCredentials`：`TaskStore` 与 `CodexThreadReader` 只需要知道"我是谁"，
/// 不该为此依赖 token。未配对时 `agentId` 是空串，配对后由调用方 `TaskStore.setAgentId(_:)` 填上。
public struct AgentIdentity: Hashable, Sendable {
    public static let nameLimit = 60
    public static let appVersionLimit = 20

    public var agentId: String
    public var name: String
    public var appVersion: String

    public init(agentId: String = "",
                name: String = AgentIdentity.localComputerName(),
                appVersion: String = AgentIdentity.bundleVersion()) {
        self.agentId = agentId
        self.name = String(name.prefix(Self.nameLimit))
        self.appVersion = String(appVersion.prefix(Self.appVersionLimit))
    }

    /// 用户看得懂的电脑名；拿不到时退回主机名并去掉 `.local` 后缀。
    /// Windows 上 Foundation 的 `localizedName` 是 nil、`hostName` 是 "localhost"，改问系统（保留设置里写的大小写）。
    public static func localComputerName() -> String {
        #if os(Windows)
        if let name = Win32.computerName(), !name.isEmpty { return name }
        #endif
        if let localized = Host.current().localizedName, !localized.isEmpty { return localized }
        let host = ProcessInfo.processInfo.hostName
        return host.hasSuffix(".local") ? String(host.dropLast(".local".count)) : host
    }

    public static func bundleVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }
}

/// 本机是哪种宿主（协议 3.5）：`TaskStore` 据此填外发 `AgentInfo` 的 `platform` 与 `capabilities`。
/// Mac 什么能力都不报（= 全部支持）；Linux / Windows 报 `remoteControl: false`（没有屏幕，手机不给屏幕那一段）与 `previews: false`
///（不托管 dev server、不转发本机端口）。「操作电脑」的工作区不在这里：`AgentHost` 建得出预览隧道就报 `AgentInfo.workspace`。
///
/// `minClientProtocol`（协议 3.6）：这台电脑要求手机至少是哪个版本，随 Relay 连接的 ready 帧发出，Relay 按组给更旧的手机回 412。
/// 3.4 及更早的手机把 `platform` 当闭集，见到 `linux` / `windows` 会拒收整份快照，所以 Linux 宿主报 3.5（以后的 Windows 同理）；Mac 不报。
public struct HostIdentity: Sendable, Equatable {
    public var platform: AgentPlatform
    public var capabilities: HostCapabilities?
    public var minClientProtocol: String?

    public init(platform: AgentPlatform, capabilities: HostCapabilities? = nil, minClientProtocol: String? = nil) {
        self.platform = platform
        self.capabilities = capabilities
        self.minClientProtocol = minClientProtocol
    }

    public static let mac = HostIdentity(platform: .macos)
    /// Linux：没有屏幕（不做远程操作）；开发预览（托管 dev server、端口转发、HMR 代理）不做；工作区的隧道由宿主注入。
    /// 手机要 ≥ 3.5（认得 `platform: "linux"`）。
    public static let linux = HostIdentity(platform: .linux, capabilities: HostCapabilities(remoteControl: false, previews: false),
                                           minClientProtocol: "3.5")
    /// Windows：没有屏幕（不做远程操作）；开发预览（托管 dev server、端口转发、HMR 代理）不做；工作区的隧道由宿主注入。
    /// 手机要 ≥ 3.5（认得 `platform: "windows"`）。
    public static let windows = HostIdentity(platform: .windows,
                                             capabilities: HostCapabilities(remoteControl: false, previews: false),
                                             minClientProtocol: "3.5")
}
