import Foundation

/// 协议版本握手（2.8 起，`PROTOCOL.md`「版本握手」）。
///
/// 三端每个发往 Relay 的请求（HTTP 与 WebSocket 握手）都带 `X-Protocol-Version: <current>`；
/// Relay 每个响应也带它自己的版本。两个方向各有一条最低线：
/// - Relay 按调用方的角色（电脑 / 手机与手表）比最低版本，不够就回 **412**——本端该升级 app；
/// - 本端要求 Relay 至少是 `minimumRelay`，成功响应里的 Relay 版本低于它时——该升级的是 Relay。
///
/// 没带版本头的一方按 `legacy` 算：版本头是 2.8 才有的，之前的实现一律视为 2.7。
public enum ProtocolVersion {
    public static let current = "3.10"
    public static let legacy = "2.7"
    /// 本端（Mac、手机、手表）要求 Relay 至少是这个版本。依赖 Relay 新行为的改动发版前，把它抬上去。
    /// 2.10：旧 Relay 会剥掉 TaskRecord / CommandResult 的 systemPermission 字段。
    /// 2.11：旧 Relay 不认 `fetchChanges` 命令，也会剥掉 `CommandResult.artifactId`。
    /// 2.12：旧 Relay 不认 `remoteControl` 命令（zod 的 kind 枚举会直接拒掉整条命令）。
    /// 2.13：旧 Relay 不认 `acp` 来源，也会剥掉 `connectorId` / `canStartTask`。
    /// 2.14：旧 Relay 会剥掉 `PendingRequest.questions` 与 `approve.answers`，手机上就选不了、答不上。
    /// 3.0：端到端加密，线上形状全换（密封信封）；2.x 的 Relay 会把密文帧整条拒掉。
    /// （2.15 的 `/agent/devices` 手机表与电脑移除手机一并由这条线盖住。）
    /// 3.7 的 `AgentInfo.workspace` 与工作区端点同样在密文里（端点走远程操作的加密预览），对 Relay 的要求不变。
    /// 3.8 的列表管理与 3.9 的 `restartConnector`、`startTask.newProjectParent` 也都在密文里，最低线不动。
    /// 3.10 的 `Notify.kind` / `connectorName` / `hasScreenshot`（手机按本机语言拼推送文案）在推送密文里，最低线不动。
    public static let minimumRelay = "3.0"
    /// 要求手机最低版本的电脑（ready 帧带 `minClientProtocol`，协议 3.6；Linux 宿主）要的 Relay 版本。
    /// 更早的 Relay 不认这个字段、也不按组回 412：旧手机见到 `platform: "linux"` 会拒收整份快照，只会一直"正在连接"。
    /// Mac 不带这个字段，照旧只要 `minimumRelay`。
    public static let minimumRelayForClientMinimum = "3.6"

    /// 请求与响应都用这个头报各自的版本。
    public static let header = "X-Protocol-Version"
    /// 412 响应里 Relay 要求的最低版本。只给日志与调试看，判定只认状态码。
    public static let minimumHeader = "X-Min-Protocol-Version"
    /// Relay 拒绝过旧 app 的状态码。选 412 而不是 426，是因为 426 已经表示"缺 `Upgrade: websocket`"，
    /// WebSocket 握手失败后的探测请求正好会撞上它。
    public static let upgradeRequiredStatus = 412

    /// 每个请求都要合进去的头。
    public static var requestHeaders: [String: String] { [header: current] }

    /// 版本号写法对不对：两到三段点分整数，每段 1–4 位数字（`3.5`、`3.10`、`4.0.1`）。与 Relay 的 `ProtocolVersionString` 一致。
    public static func isWellFormed(_ version: String) -> Bool {
        let segments = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(segments.count) else { return false }
        return segments.allSatisfy { segment in
            (1...4).contains(segment.count) && segment.allSatisfy { ("0"..."9").contains($0) }
        }
    }

    /// `a` 是否比 `b` 旧。按点分的整数逐段比（`2.10` 比 `2.9` 新），缺的段当 0，解析不了的段当 0。
    public static func isOlder(_ a: String, than b: String) -> Bool {
        let left = parts(a), right = parts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// 看一个 Relay 响应能不能说明两边版本对不上。
    ///
    /// Relay 版本只在成功响应（2xx、101、304）上判：Cloudflare 边缘或代理自己回的 502 之类也不带版本头，
    /// 拿它当"Relay 太旧"会把一次网络抖动说成要升级。旧 Relay 的成功响应不带头，按 `legacy` 算。
    public static func incompatibility(status: Int, relayVersion: String?,
                                       minimumRelay: String = minimumRelay) -> ProtocolIncompatibility? {
        if status == upgradeRequiredStatus { return .appOutdated }
        let succeeded = (200..<300).contains(status) || status == 101 || status == 304
        guard succeeded else { return nil }
        let relay = relayVersion?.trimmingCharacters(in: .whitespaces) ?? ""
        return isOlder(relay.isEmpty ? legacy : relay, than: minimumRelay) ? .relayOutdated : nil
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
    }
}

/// 两端版本对不上。界面据此提示升级哪一边；重试没有意义，但也不清凭据。
public enum ProtocolIncompatibility: Error, Equatable, Sendable {
    /// Relay 回了 412：这个 app 太旧，Relay 已经不认它的协议了。
    case appOutdated
    /// Relay 太旧，低于本端要求的 `ProtocolVersion.minimumRelay`。
    case relayOutdated
}
