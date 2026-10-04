import Foundation
import XCTest
import BotBusProtocol

/// 终端（「操作电脑」第二期）的消息与加密：类型、序号、方向、握手、跨连接。
final class TerminalWireTests: XCTestCase {
    private let key = PairKey.random().derived(.remoteControl)
    private let agentId = "hV3nQ7pLxK2mR8sTfW4bZQ"
    private let sessionId = "EBESExQVFhcYGRobHB0eHw"
    private let clientNonce = "ICEiIyQlJicoKSorLC0uLw"

    private func pair() throws -> (computer: TerminalCipher, phone: TerminalCipher) {
        var computer = try TerminalCipher(key: key, agentId: agentId, sessionId: sessionId, clientNonce: clientNonce,
                                          role: .computer)
        var phone = try TerminalCipher(key: key, agentId: agentId, sessionId: sessionId, clientNonce: clientNonce,
                                       role: .phone)
        try phone.openHello(try computer.sealHello())
        XCTAssertEqual(phone.serverNonce, computer.serverNonce)
        return (computer, phone)
    }

    func testMessagesRoundTripThroughKindAndPayload() throws {
        let messages: [TerminalMessage] = [
            .hello(serverNonce: Data(repeating: 7, count: 16)), .output(Data("你好\r\n".utf8)), .input(Data([3])),
            .resize(cols: 120, rows: 40), .exit(code: -1), .exit(code: 130), .lock(armed: true), .lock(armed: false),
            .replayEnd,
        ]
        for message in messages {
            XCTAssertEqual(try TerminalMessage.decode(kind: message.kind, payload: message.payload), message)
        }
        XCTAssertEqual(TerminalMessage.resize(cols: 0x0102, rows: 0x0304).payload, Data([1, 2, 3, 4]))
        XCTAssertEqual(TerminalMessage.exit(code: -2).payload, Data([0xFF, 0xFF, 0xFF, 0xFE]))
        XCTAssertEqual(TerminalMessage.input(Data()).direction, .phoneToComputer)
        XCTAssertEqual(TerminalMessage.replayEnd.direction, .computerToPhone)
    }

    func testDecodeRejectsMalformedPayloads() {
        let bad: [(UInt8, Data)] = [
            (0, Data(count: 15)), (3, Data(count: 3)), (4, Data(count: 5)), (5, Data([2])), (5, Data()),
            (6, Data([0])), (7, Data()),
        ]
        for (kind, payload) in bad {
            XCTAssertThrowsError(try TerminalMessage.decode(kind: kind, payload: payload), "kind \(kind)")
        }
    }

    func testFramePlaintextLayout() throws {
        let plain = TerminalFrame.plaintext(.output(Data("ab".utf8)), seq: 0x0102)
        XCTAssertEqual(plain, Data([1, 0, 0, 0, 0, 0, 0, 1, 2, 0x61, 0x62]))
        let parsed = try TerminalFrame.parse(plain)
        XCTAssertEqual(parsed.kind, 1)
        XCTAssertEqual(parsed.seq, 0x0102)
        XCTAssertEqual(parsed.payload, Data("ab".utf8))
        XCTAssertThrowsError(try TerminalFrame.parse(Data([1, 0, 0])))
    }

    func testHandshakeThenBothDirections() throws {
        var (computer, phone) = try pair()
        let out = try computer.seal(.output(Data("ls\r\n".utf8)))
        XCTAssertEqual(try phone.open(out), .output(Data("ls\r\n".utf8)))
        XCTAssertEqual(try phone.open(try computer.seal(.replayEnd)), .replayEnd)
        let input = try phone.seal(.input(Data("pwd\r".utf8)))
        XCTAssertEqual(try computer.open(input), .input(Data("pwd\r".utf8)))
        XCTAssertEqual(try computer.open(try phone.seal(.resize(cols: 80, rows: 24))), .resize(cols: 80, rows: 24))
    }

    func testNothingFlowsBeforeTheHandshake() throws {
        var phone = try TerminalCipher(key: key, agentId: agentId, sessionId: sessionId, clientNonce: clientNonce,
                                       role: .phone)
        XCTAssertThrowsError(try phone.seal(.input(Data([1])))) { XCTAssertEqual($0 as? TerminalWireError, .notReady) }
        var computer = try TerminalCipher(key: key, agentId: agentId, sessionId: sessionId, clientNonce: clientNonce,
                                          role: .computer)
        XCTAssertThrowsError(try computer.seal(.output(Data()))) { XCTAssertEqual($0 as? TerminalWireError, .notReady) }
        XCTAssertThrowsError(try phone.sealHello(), "只有电脑发握手")
    }

    func testSequenceMustIncreaseByExactlyOne() throws {
        var (computer, phone) = try pair()
        let first = try computer.seal(.output(Data("a".utf8)))
        let second = try computer.seal(.output(Data("b".utf8)))
        XCTAssertThrowsError(try phone.open(second)) {
            XCTAssertEqual($0 as? TerminalWireError, .outOfOrder(expected: 0, got: 1))
        }
        XCTAssertEqual(try phone.open(first), .output(Data("a".utf8)))
        XCTAssertEqual(try phone.open(second), .output(Data("b".utf8)))
        XCTAssertThrowsError(try phone.open(second), "重放同一条") {
            XCTAssertEqual($0 as? TerminalWireError, .outOfOrder(expected: 2, got: 1))
        }
    }

    func testWrongDirectionIsRejected() throws {
        var (computer, phone) = try pair()
        XCTAssertThrowsError(try phone.seal(.output(Data()))) { XCTAssertEqual($0 as? TerminalWireError, .wrongDirection(1)) }
        XCTAssertThrowsError(try computer.seal(.input(Data()))) { XCTAssertEqual($0 as? TerminalWireError, .wrongDirection(2)) }
        // 电脑自己封的 m2c 包拿回电脑上解：AAD 的方向不同，解不开。
        let own = try computer.seal(.output(Data()))
        XCTAssertThrowsError(try computer.open(own)) { XCTAssertEqual($0 as? TerminalWireError, .cannotOpen) }
    }

    /// Relay 把旧连接里手机发过的输入原样灌进一条新连接：`sn` 变了，解不开。
    func testMessagesFromAnotherConnectionCannotBeOpened() throws {
        var (_, oldPhone) = try pair()
        let replayed = try oldPhone.seal(.input(Data("rm -rf ~\r".utf8)))
        var (newComputer, _) = try pair()
        XCTAssertThrowsError(try newComputer.open(replayed)) { XCTAssertEqual($0 as? TerminalWireError, .cannotOpen) }
        // 换个 cn 的握手也不认。
        var stranger = try TerminalCipher(key: key, agentId: agentId, sessionId: sessionId,
                                          clientNonce: TerminalCipher.newToken(), role: .phone)
        var computer = try TerminalCipher(key: key, agentId: agentId, sessionId: sessionId, clientNonce: clientNonce,
                                          role: .computer)
        XCTAssertThrowsError(try stranger.openHello(try computer.sealHello())) {
            XCTAssertEqual($0 as? TerminalWireError, .cannotOpen)
        }
    }

    func testTokensAndAADs() throws {
        XCTAssertTrue(TerminalCipher.isValidToken(TerminalCipher.newToken()))
        XCTAssertFalse(TerminalCipher.isValidToken("abc"))
        XCTAssertFalse(TerminalCipher.isValidToken("EBESExQVFhcYGRobHB0eHx"), "末位不规范")
        XCTAssertThrowsError(try TerminalCipher(key: key, agentId: agentId, sessionId: "a:b", clientNonce: clientNonce,
                                                role: .phone)) { XCTAssertEqual($0 as? TerminalWireError, .badToken) }
        XCTAssertEqual(SealingContext.terminalHello(agentId: "A", sessionId: "S", clientNonce: "C"), "rc:A:term:S:C:hello")
        XCTAssertEqual(SealingContext.terminal(agentId: "A", sessionId: "S", clientNonce: "C", serverNonce: "N",
                                               direction: .computerToPhone), "rc:A:term:S:C:N:m2c")
        XCTAssertEqual(SealingContext.terminal(agentId: "A", sessionId: "S", clientNonce: "C", serverNonce: "N",
                                               direction: .phoneToComputer), "rc:A:term:S:C:N:c2m")
    }

    func testCloseCodesOnTheWire() {
        XCTAssertEqual(TerminalCloseCode.normal, 1000)
        XCTAssertEqual(TerminalCloseCode.unsupportedData, 1003)
        XCTAssertEqual(TerminalCloseCode.violation, 1008)
        XCTAssertEqual(TerminalCloseCode.internalError, 1011)
        XCTAssertEqual(TerminalCloseCode.slowConsumer, 4008)
        XCTAssertEqual(TerminalCloseCode.sessionGone, 4404)
        XCTAssertEqual(TerminalCloseCode.tooManyConnections, 4429)
    }

    func testSessionInfoOmitsAbsentExit() throws {
        let info = TerminalSessionInfo(id: sessionId, title: "zsh", cwd: "/Users/me", cols: 80, rows: 24,
                                       createdAt: 1_790_000_000_000)
        let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        XCTAssertFalse(json.contains("exited"))
        XCTAssertEqual(try JSONDecoder().decode(TerminalSessionInfo.self, from: Data(json.utf8)), info)
    }
}
