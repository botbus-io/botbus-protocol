import XCTest
@testable import BotBusConnectorKit

final class AgentIdentityTests: XCTestCase {
    #if os(Windows)
    /// Windows 上 Foundation 的 `hostName` 是 "localhost"：手机上的电脑名得是系统里的设备名称。
    func testWindowsComputerNameIsTheDeviceName() throws {
        let name = AgentIdentity.localComputerName()
        XCTAssertNotEqual(name.lowercased(), "localhost")
        let netbios = try XCTUnwrap(ProcessInfo.processInfo.environment["COMPUTERNAME"])
        // NetBIOS 名是设备名称的大写、最多 15 个字符。
        XCTAssertTrue(name.uppercased().hasPrefix(netbios.uppercased()), "\(name) vs \(netbios)")
    }
    #endif

    func testNameIsNeverEmpty() {
        XCTAssertFalse(AgentIdentity.localComputerName().isEmpty)
    }
}
