import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BotBusConnectors

/// 连接器自己发的 HTTP 请求不带 URLCache：swift-corelibs-foundation（Linux / Windows）上，带 URLCache 的会话里
/// 等着 `data(for:)` 的任务在查缓存的空当被取消，进程会 trap 在 `TaskRegistry.swift`（见 `URLSessionDshHTTPTransport`
/// 的注释）。两种平台都跑。
final class UncachedURLSessionTests: XCTestCase {
    func testDshTransportHasNoCache() {
        let configuration = URLSessionDshHTTPTransport().session.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, URLSessionDshHTTPTransport.timeout)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testCodexBridgeSessionHasNoCache() {
        let configuration = CodexBridgeProcessLauncher.sessionConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 28)
        XCTAssertNil(URLSession(configuration: configuration).configuration.urlCache)
    }
}
