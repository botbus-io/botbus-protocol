import Foundation

/// 线上 Relay 的地址。Mac、手机、手表共用这一份，免得三处常量各改各的。
public enum RelayEndpoint {
    public static let defaultURLString = "https://relay.botbus.io"

    public static var defaultURL: URL { URL(string: defaultURLString)! }
}
