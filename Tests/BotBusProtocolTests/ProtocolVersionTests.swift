import XCTest
@testable import BotBusProtocol

final class ProtocolVersionTests: XCTestCase {
    /// 3.0 的密封信封要 Relay 认得——2.x 的 Relay 会把密文帧整条拒掉，而它合并出来的明文快照 3.0 的客户端也解不开。
    /// （2.15 的手机表与电脑移除手机、2.14 的 `questions`、2.13 的 `acp` 等更早的依赖一并由这条线盖住。）
    /// 3.1 只加了 `dsh` 枚举、3.2 只加了模型与思考强度的可选字段、3.3 只加了自动批准的可选字段、3.4 的 worktree 字段与 `mergeWorktree` 命令
    /// 同样都在密文里：Relay 只见密文、不解析它们，所以对 Relay 的要求仍是 3.0。
    /// 3.6 的 `minClientProtocol` 只有要求手机版本的电脑（Linux）才发，它们另要 Relay 3.6（`minimumRelayForClientMinimum`）。
    /// 3.7 的失败诊断（密文里的可选字段）、`AgentInfo.workspace` 与工作区端点也都在密文里，最低线不动。
    func testSealedWireRequiresRelayThatSpeaksIt() {
        XCTAssertEqual(ProtocolVersion.current, "3.7")
        XCTAssertEqual(ProtocolVersion.minimumRelay, "3.0")
        XCTAssertEqual(ProtocolVersion.incompatibility(status: 200, relayVersion: "2.14"), .relayOutdated)
        XCTAssertEqual(ProtocolVersion.incompatibility(status: 200, relayVersion: "2.11"), .relayOutdated)
        XCTAssertNil(ProtocolVersion.incompatibility(status: 200, relayVersion: "3.0"))
    }

    func testHostsThatRequireANewerPhoneNeedTheRelayThatEnforcesIt() {
        XCTAssertEqual(ProtocolVersion.minimumRelayForClientMinimum, "3.6")
        XCTAssertEqual(ProtocolVersion.incompatibility(status: 101, relayVersion: "3.5",
                                                       minimumRelay: ProtocolVersion.minimumRelayForClientMinimum), .relayOutdated)
        XCTAssertNil(ProtocolVersion.incompatibility(status: 101, relayVersion: "3.6",
                                                     minimumRelay: ProtocolVersion.minimumRelayForClientMinimum))
        XCTAssertFalse(ProtocolVersion.isOlder(ProtocolVersion.current, than: ProtocolVersion.minimumRelayForClientMinimum))
    }

    func testWellFormedVersions() {
        for good in ["3.5", "3.10", "4.0.1", "10.2"] { XCTAssertTrue(ProtocolVersion.isWellFormed(good), good) }
        for bad in ["", "3", "3.", ".5", "3.5.0.1", "v3.5", "3.5-beta", " 3.5", "12345.1", "3..5"] {
            XCTAssertFalse(ProtocolVersion.isWellFormed(bad), bad)
        }
    }

    func testComparesNumericallyBySegment() {
        XCTAssertTrue(ProtocolVersion.isOlder("2.6", than: "2.7"))
        XCTAssertTrue(ProtocolVersion.isOlder("2.9", than: "2.10"))
        XCTAssertTrue(ProtocolVersion.isOlder("2", than: "2.1"))
        XCTAssertFalse(ProtocolVersion.isOlder("2.7", than: "2.7"))
        XCTAssertFalse(ProtocolVersion.isOlder("2.7.0", than: "2.7"))
        XCTAssertFalse(ProtocolVersion.isOlder("3.0", than: "2.10"))
    }

    func testCurrentIsNotOlderThanTheFloors() {
        XCTAssertFalse(ProtocolVersion.isOlder(ProtocolVersion.current, than: ProtocolVersion.minimumRelay))
        XCTAssertFalse(ProtocolVersion.isOlder(ProtocolVersion.current, than: ProtocolVersion.legacy))
    }

    func test412MeansThisAppIsOutdated() {
        XCTAssertEqual(ProtocolVersion.incompatibility(status: 412, relayVersion: "2.7"), .appOutdated)
        XCTAssertEqual(ProtocolVersion.incompatibility(status: 412, relayVersion: nil), .appOutdated)
    }

    func testOldRelayIsOnlyJudgedOnSuccessfulResponses() {
        for status in [200, 201, 204, 101, 304] {
            XCTAssertEqual(ProtocolVersion.incompatibility(status: status, relayVersion: "2.7", minimumRelay: "2.8"),
                           .relayOutdated, "\(status)")
        }
        // 边缘或代理自己回的错误页不带版本头，不能当成 Relay 太旧。
        for status in [401, 404, 426, 500, 502, 503] {
            XCTAssertNil(ProtocolVersion.incompatibility(status: status, relayVersion: nil, minimumRelay: "2.8"),
                         "\(status)")
        }
    }

    func testMissingRelayHeaderCountsAsLegacy() {
        XCTAssertEqual(ProtocolVersion.incompatibility(status: 200, relayVersion: nil, minimumRelay: "2.8"),
                       .relayOutdated)
        XCTAssertNil(ProtocolVersion.incompatibility(status: 200, relayVersion: nil, minimumRelay: "2.7"))
        XCTAssertNil(ProtocolVersion.incompatibility(status: 200, relayVersion: "2.8", minimumRelay: "2.8"))
        XCTAssertNil(ProtocolVersion.incompatibility(status: 200, relayVersion: "2.9", minimumRelay: "2.8"))
    }
}
