import XCTest
@testable import BotBusProtocol

final class RelayEndpointTests: XCTestCase {
    func testDefaultURL() {
        XCTAssertEqual(RelayEndpoint.defaultURL.host, "relay.botbus.io")
    }
}
