import Foundation

/// 协议 3.7：电脑对一次失败的诊断。认出常见原因时随 `CommandResult.diagnosis`（命令在被后端接受前失败）或
/// `TaskRecord.diagnosis`（任务跑起来后失败）带给手机，手机按类别给出本地化的原因与操作步骤。
/// 只是判断，不替代原话：`error` / `lastMessage` 照旧原样保留。`kind` 与 `folder` 都是开集，不认得的值原样保留：
/// 不认得的 `kind` 客户端当作没有诊断，不认得的 `folder` 客户端当作 `other`。
public struct FailureDiagnosis: Codable, Hashable, Sendable {
    public var kind: Kind
    /// 只随 `folderAccessDenied`：项目落在哪个受保护的位置。系统拒绝访问（EPERM，macOS 上就是文件夹授权）时带；普通的目录权限问题（EACCES）省略。其他平台照样填，客户端只在 Mac 上用它。
    public var folder: Folder?
    /// 只随 `usageLimit`：电脑从原话里读到的额度恢复时间（秒精度 UTC），读不到时省略。
    public var resetsAt: String?

    public init(kind: Kind, folder: Folder? = nil, resetsAt: String? = nil) {
        self.kind = kind
        self.folder = folder
        self.resetsAt = resetsAt
    }

    public static func folderAccessDenied(_ folder: Folder) -> FailureDiagnosis {
        FailureDiagnosis(kind: .folderAccessDenied, folder: folder)
    }
    public static let agentNotInstalled = FailureDiagnosis(kind: .agentNotInstalled)
    public static let notSignedIn = FailureDiagnosis(kind: .notSignedIn)
    public static let signInExpired = FailureDiagnosis(kind: .signInExpired)
    public static func usageLimit(resetsAt: String? = nil) -> FailureDiagnosis {
        FailureDiagnosis(kind: .usageLimit, resetsAt: resetsAt)
    }
    public static let projectMissing = FailureDiagnosis(kind: .projectMissing)

    public enum Kind: RawRepresentable, Codable, Sendable, Hashable {
        /// 系统不让 BotBus（和它起的 agent）读项目所在的文件夹（macOS 的「文件与文件夹」授权，或其他平台的目录权限）。
        case folderAccessDenied
        /// 电脑上找不到 agent 的可执行文件。
        case agentNotInstalled
        /// agent 没登录。
        case notSignedIn
        /// 登录过，但凭据过期或被作废。
        case signInExpired
        /// 用量额度用完或被限流。
        case usageLimit
        /// 项目目录不在了。
        case projectMissing
        /// 这个版本还不认得的类别。
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "folderAccessDenied": self = .folderAccessDenied
            case "agentNotInstalled": self = .agentNotInstalled
            case "notSignedIn": self = .notSignedIn
            case "signInExpired": self = .signInExpired
            case "usageLimit": self = .usageLimit
            case "projectMissing": self = .projectMissing
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .folderAccessDenied: "folderAccessDenied"
            case .agentNotInstalled: "agentNotInstalled"
            case .notSignedIn: "notSignedIn"
            case .signInExpired: "signInExpired"
            case .usageLimit: "usageLimit"
            case .projectMissing: "projectMissing"
            case .unknown(let value): value
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public enum Folder: RawRepresentable, Codable, Sendable, Hashable {
        case desktop, documents, downloads, iCloudDrive, removableVolume, networkVolume
        /// 其余受保护的位置。
        case other
        /// 这个版本还不认得的位置。
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "desktop": self = .desktop
            case "documents": self = .documents
            case "downloads": self = .downloads
            case "iCloudDrive": self = .iCloudDrive
            case "removableVolume": self = .removableVolume
            case "networkVolume": self = .networkVolume
            case "other": self = .other
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .desktop: "desktop"
            case .documents: "documents"
            case .downloads: "downloads"
            case .iCloudDrive: "iCloudDrive"
            case .removableVolume: "removableVolume"
            case .networkVolume: "networkVolume"
            case .other: "other"
            case .unknown(let value): value
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}
