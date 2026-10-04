import XCTest
@testable import BotBusProtocol

final class RelayEndpointTests: XCTestCase {
    func testDefaultURL() {
        XCTAssertEqual(RelayEndpoint.defaultURL.host, "relay.botbus.io")
    }

    func testEnvironmentClassification() {
        XCTAssertEqual(RelayEnvironment(url: URL(string: "https://relay.botbus.io")!), .production)
        XCTAssertEqual(RelayEnvironment(url: URL(string: "HTTPS://Relay.BotBus.io/")!), .production)
        XCTAssertEqual(RelayEnvironment(url: URL(string: "https://relay-test.botbus.io")!), .test)
        let custom = URL(string: "http://127.0.0.1:8799")!
        XCTAssertEqual(RelayEnvironment(url: custom), .custom(custom))
        XCTAssertEqual(RelayEnvironment(urlString: " https://relay-test.botbus.io "), .test)
        let ported = URL(string: "https://relay.botbus.io:8443")!
        XCTAssertEqual(RelayEnvironment(url: ported), .custom(ported))
        XCTAssertEqual(RelayEnvironment(urlString: "https://relay-test.botbus.io:443"), .test)
        XCTAssertNil(RelayEnvironment(urlString: "not a url"))
        XCTAssertNil(RelayEnvironment(urlString: "ftp://relay.botbus.io"))
        XCTAssertEqual(RelayEnvironment.test.url, RelayEndpoint.testURL)
        XCTAssertTrue(RelayEnvironment.production.isProduction)
        XCTAssertFalse(RelayEnvironment.test.isProduction)
    }
}
