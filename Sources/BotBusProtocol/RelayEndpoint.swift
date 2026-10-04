import Foundation

/// 线上 Relay 的地址。Mac、手机、手表共用这一份，免得三处常量各改各的。
public enum RelayEndpoint {
    public static let defaultURLString = "https://relay.botbus.io"
    /// 测试环境（`relay/wrangler.jsonc` 的 `env.test`），只经开发者选项切过去。
    public static let testURLString = "https://relay-test.botbus.io"

    public static var defaultURL: URL { URL(string: defaultURLString)! }
    public static var testURL: URL { URL(string: testURLString)! }
}

/// 一个 Relay 地址属于哪套环境。按主机名判断：scheme、大小写、末尾斜杠都不算区别；
/// 带了非默认端口的（`relay.botbus.io:8443`）不是那两台，算自定义。
public enum RelayEnvironment: Equatable, Sendable {
    case production
    case test
    case custom(URL)

    public init(url: URL) {
        let defaultPort = url.port == nil || url.port == (url.scheme?.lowercased() == "http" ? 80 : 443)
        switch (url.host?.lowercased(), defaultPort) {
        case (RelayEndpoint.defaultURL.host, true): self = .production
        case (RelayEndpoint.testURL.host, true): self = .test
        default: self = .custom(url)
        }
    }

    /// 输入框里的字符串；不是带主机名的 http(s) 地址时返回 nil。
    public init?(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        self.init(url: url)
    }

    public var url: URL {
        switch self {
        case .production: RelayEndpoint.defaultURL
        case .test: RelayEndpoint.testURL
        case .custom(let url): url
        }
    }

    public var isProduction: Bool { self == .production }
}
