import Foundation
import XCTest
import BotBusProtocol

/// 「操作电脑」工作区（协议 3.7）的线上类型：与 `protocol-fixtures/workspace/` 逐键对照。
/// Android 的 `WorkspaceWireTest` 读同一批样本（计划 1B）。
final class WorkspaceWireTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: FixtureRoundTripTests.fixturesDir.appendingPathComponent("workspace/\(name)"))
    }

    private func assertRoundTrips<T: Codable>(_ type: T.Type, _ name: String,
                                              file: StaticString = #filePath, line: UInt = #line) throws {
        let original = try fixture(name)
        let value = try JSONDecoder().decode(type, from: original)
        let reencoded = try JSONEncoder().encode(value)
        let expected = try JSONSerialization.jsonObject(with: original) as! NSObject
        let produced = try JSONSerialization.jsonObject(with: reencoded) as! NSObject
        XCTAssertEqual(expected, produced, "\(name) 往返后不一致", file: file, line: line)
    }

    func testStatusRoundTripsAndFeatures() throws {
        try assertRoundTrips(WorkspaceStatus.self, "status-mac.json")
        try assertRoundTrips(WorkspaceStatus.self, "status-linux.json")
        try assertRoundTrips(WorkspaceStatus.self, "status-legacy.json")

        let mac = try JSONDecoder().decode(WorkspaceStatus.self, from: fixture("status-mac.json"))
        XCTAssertTrue(mac.supports(WorkspaceFeature.files))
        XCTAssertTrue(mac.supports(WorkspaceFeature.screen))
        XCTAssertFalse(mac.supports(WorkspaceFeature.terminal))
        XCTAssertEqual(mac.armedUntil, 1_790_000_600_000)

        let linux = try JSONDecoder().decode(WorkspaceStatus.self, from: fixture("status-linux.json"))
        XCTAssertFalse(linux.supports(WorkspaceFeature.screen))

        // 3.6 的 Mac 不报 features：只有屏幕。
        let legacy = try JSONDecoder().decode(WorkspaceStatus.self, from: fixture("status-legacy.json"))
        XCTAssertNil(legacy.features)
        XCTAssertTrue(legacy.supports(WorkspaceFeature.screen))
        XCTAssertFalse(legacy.supports(WorkspaceFeature.files))
    }

    func testListingRoundTripsAndUnknownKindIsOther() throws {
        try assertRoundTrips(WorkspaceListing.self, "listing.json")
        let listing = try JSONDecoder().decode(WorkspaceListing.self, from: fixture("listing.json"))
        XCTAssertEqual(listing.entries.map(\.kind), [.dir, .dir, .file, .file, .file])
        XCTAssertEqual(listing.entries[1].link, true)
        XCTAssertEqual(listing.truncated, true)

        let future = Data(#"{"name":"x","kind":"socket","mtimeMs":0}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceEntry.self, from: future).kind, .other)
    }

    /// 第三期：Windows 宿主的 `/status` 与「此电脑」那一层（路径是空串）。
    func testWindowsStatusAndDriveListing() throws {
        try assertRoundTrips(WorkspaceStatus.self, "status-windows.json")
        let windows = try JSONDecoder().decode(WorkspaceStatus.self, from: fixture("status-windows.json"))
        XCTAssertEqual(windows.platform, "windows")
        XCTAssertEqual(windows.home, #"C:\Users\me"#)
        XCTAssertTrue(windows.supports(WorkspaceFeature.terminal))
        XCTAssertFalse(windows.supports(WorkspaceFeature.screen))

        try assertRoundTrips(WorkspaceListing.self, "listing-drives.json")
        let drives = try JSONDecoder().decode(WorkspaceListing.self, from: fixture("listing-drives.json"))
        XCTAssertEqual(drives.path, "", "「此电脑」是空串")
        XCTAssertEqual(drives.entries.map(\.name), ["C:", "D:"])
        XCTAssertTrue(drives.entries.allSatisfy { $0.kind == .dir && $0.git == nil && $0.size == nil })
        XCTAssertNil(drives.repoRoot)
    }

    /// 第三期：Linux 上不是 UTF-8 的名字标 `undecodable`；Linux / Windows 进不了废纸篓回 `noTrash`。
    func testUndecodableNamesAndNoTrash() throws {
        try assertRoundTrips(WorkspaceListing.self, "listing-undecodable.json")
        let listing = try JSONDecoder().decode(WorkspaceListing.self, from: fixture("listing-undecodable.json"))
        XCTAssertNil(listing.entries[0].undecodable)
        XCTAssertEqual(listing.entries[1].undecodable, true)
        XCTAssertEqual(listing.entries[1].kind, .other)
        XCTAssertEqual(listing.entries[1].name, "caf\u{FFFD}.txt")
        XCTAssertThrowsError(try WorkspaceReply.decode(WorkspaceEmpty.self, from: fixture("failure-no-trash.json"))) {
            XCTAssertEqual(($0 as? WorkspaceFailure)?.code, .noTrash)
        }
        // 只写 true：没有的时候整个键省略。
        let plain = try JSONEncoder().encode(WorkspaceEntry(name: "a", kind: .file, mtimeMs: 0))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("undecodable"))
    }

    func testFailureEnvelope() throws {
        XCTAssertThrowsError(try WorkspaceReply.decode(WorkspaceEmpty.self, from: fixture("failure-conflict.json"))) {
            let failure = $0 as? WorkspaceFailure
            XCTAssertEqual(failure?.code, .conflict)
            XCTAssertEqual(failure?.current, WorkspaceFileStamp(mtimeMs: 1_790_000_000_123, size: 2048))
        }
        XCTAssertThrowsError(try WorkspaceReply.decode(WorkspaceEmpty.self, from: fixture("failure-unknown-code.json"))) {
            XCTAssertEqual(($0 as? WorkspaceFailure)?.code, .failed, "不认得的 code 按 failed")
        }
        // 成功的回复照成功类型解。
        let stamp = try WorkspaceReply.decode(WorkspaceFileStamp.self, from: Data(#"{"mtimeMs":5,"size":6}"#.utf8))
        XCTAssertEqual(stamp, WorkspaceFileStamp(mtimeMs: 5, size: 6))
        // 编出来的失败能被同一套解开。
        let encoded = WorkspaceReply.encodeFailure(WorkspaceFailure(.locked))
        XCTAssertThrowsError(try WorkspaceReply.decode(WorkspaceEmpty.self, from: encoded)) {
            XCTAssertEqual(($0 as? WorkspaceFailure)?.code, .locked)
        }
    }

    func testEnvelopePlaintextMatchesFixture() throws {
        let body = WorkspaceRequest.Write(path: "/Users/me/Projects/demo/README.md", content: "+/8=",
                                          expect: WorkspaceFileStamp(mtimeMs: 1_790_000_000_123, size: 2048))
        let plaintext = try WorkspaceEnvelope.plaintext(body, path: WorkspacePath.fsWrite, stamp: 1_790_000_000_500,
                                                        channel: "AAECAwQFBgcICQoLDA0ODw")
        let produced = try JSONSerialization.jsonObject(with: plaintext) as! NSObject
        let expected = try JSONSerialization.jsonObject(with: fixture("request-write.json")) as! NSObject
        XCTAssertEqual(produced, expected)

        // 旧页面不带通道号。
        let legacy = try WorkspaceEnvelope.plaintext(WorkspaceRequest.Arm(on: true), path: WorkspacePath.arm,
                                                     stamp: 1, channel: nil)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        XCTAssertNil(fields["c"])
        XCTAssertEqual(fields["on"] as? Bool, true)
    }

    func testChannels() {
        let channel = WorkspaceEnvelope.newChannel()
        XCTAssertEqual(channel.count, 22)
        XCTAssertTrue(WorkspaceEnvelope.isValidChannel(channel))
        XCTAssertNotEqual(channel, WorkspaceEnvelope.newChannel())
        XCTAssertTrue(WorkspaceEnvelope.isValidChannel("AAECAwQFBgcICQoLDA0ODw"))
        XCTAssertFalse(WorkspaceEnvelope.isValidChannel("short"))
        XCTAssertFalse(WorkspaceEnvelope.isValidChannel("AAECAwQFBgcICQoLDA0ODw=="))
    }

    /// 通道号必须是规范的 base64url：22 个字符、都在字母表里、最后一个字符的多余位为 0。
    func testChannelValidationIsStrict() {
        // 最后一个字符只带 2 个有效位，低 4 位必须是 0：只有 A Q g w 合法。
        for last in ["A", "Q", "g", "w"] {
            XCTAssertTrue(WorkspaceEnvelope.isValidChannel("AAECAwQFBgcICQoLDA0OD" + last), "末位 \(last) 应合法")
        }
        XCTAssertFalse(WorkspaceEnvelope.isValidChannel("AAECAwQFBgcICQoLDA0OD+"), "+ 不在 base64url 字母表里")
        XCTAssertFalse(WorkspaceEnvelope.isValidChannel("AAECAwQFBgcICQoLDA0OD/"), "/ 不在 base64url 字母表里")
        XCTAssertFalse(WorkspaceEnvelope.isValidChannel("AAECAwQFBgcICQoLDA0ODx"), "末位多余位不为 0")
        XCTAssertFalse(WorkspaceEnvelope.isValidChannel("AAECAwQFBgcICQoLDA0OD"), "21 个字符")
        XCTAssertFalse(WorkspaceEnvelope.isValidChannel("AAECAwQFBgcICQoLDA0ODwA"), "23 个字符")
        XCTAssertFalse(WorkspaceEnvelope.isValidChannel("AAECAwQFBgcICQoLDA0OD "), "空白字符")
        XCTAssertFalse(WorkspaceEnvelope.isValidChannel("AAECAwQFBgcICQoLDA0ODé"), "非 ASCII 字符")
        XCTAssertFalse(WorkspaceEnvelope.isValidChannel(""))
    }

    func testBoundAADs() {
        XCTAssertEqual(SealingContext.remoteControlResponse(agentId: "a", channel: "c", stamp: 7), "rc:a:res:c:7")
        XCTAssertEqual(SealingContext.remoteControlPacket(agentId: "a", channel: "c", stamp: 7, index: 2), "rc:a:res:c:7:2")
    }

    func testPacketsFrameAndDrainAcrossPartialReads() throws {
        let sealer = Sealer(pairKey: .random(), purpose: .remoteControl)
        let first = try sealer.sealRaw(WorkspacePacket.plaintext(.header, Data("{}".utf8)), aad: "x:0")
        let second = try sealer.sealRaw(WorkspacePacket.plaintext(.data, Data([1, 2, 3])), aad: "x:1")
        let wire = WorkspacePacket.frame(first) + WorkspacePacket.frame(second)

        var buffer = Data(wire.prefix(10))
        XCTAssertEqual(try WorkspacePacket.drain(&buffer), [], "不完整的包留在缓冲区")
        buffer.append(wire.dropFirst(10))
        let packets = try WorkspacePacket.drain(&buffer)
        XCTAssertEqual(packets, [first, second])
        XCTAssertTrue(buffer.isEmpty)

        let opened = try sealer.openRaw(packets[1], aad: "x:1")
        XCTAssertEqual(opened, Data([WorkspacePacket.Kind.data.rawValue, 1, 2, 3]))
        XCTAssertThrowsError(try sealer.openRaw(packets[1], aad: "x:0"), "换序解不开")

        var oversized = Data([0x7F, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try WorkspacePacket.drain(&oversized), "长度越界当坏数据")
    }

    // MARK: - 失败信封与空回复的严格解码

    func testMalformedFailureIsStillAFailure() {
        for body in [#"{"failure":{"code":5}}"#, #"{"failure":"nope"}"#, #"{"failure":null}"#, #"{"failure":{}}"#] {
            XCTAssertThrowsError(try WorkspaceReply.decode(WorkspaceEmpty.self, from: Data(body.utf8)), body) {
                let failure = $0 as? WorkspaceFailure
                XCTAssertEqual(failure?.code, .failed, body)
                XCTAssertEqual(failure?.detail, "malformed failure", body)
            }
            // 成功类型不是空回复时也一样：有 `failure` 键就是失败，不会被当成成功。
            XCTAssertThrowsError(try WorkspaceReply.decode(WorkspaceUploadProgress.self, from: Data(body.utf8)), body) {
                XCTAssertTrue($0 is WorkspaceFailure, body)
            }
        }
    }

    func testEmptyReplyRequiresAnObject() throws {
        XCTAssertNoThrow(try WorkspaceReply.decode(WorkspaceEmpty.self, from: Data("{}".utf8)))
        XCTAssertEqual(try JSONEncoder().encode(WorkspaceEmpty()), Data("{}".utf8))
        for body in ["[]", "null", "7", #""x""#, "true"] {
            XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceEmpty.self, from: Data(body.utf8)), body)
            XCTAssertThrowsError(try WorkspaceReply.decode(WorkspaceEmpty.self, from: Data(body.utf8)), body) {
                XCTAssertFalse($0 is WorkspaceFailure, "不是失败，只是解不开：\(body)")
            }
        }
    }

    // MARK: - 请求明文

    func testEnvelopePlaintextRejectsReservedKeys() {
        struct Reserved: Encodable {
            var p: String?
            var t: Int?
            var c: String?
        }
        for body in [Reserved(p: "x"), Reserved(t: 1), Reserved(c: "x")] {
            XCTAssertThrowsError(try WorkspaceEnvelope.plaintext(body, path: WorkspacePath.status, stamp: 1, channel: nil)) {
                XCTAssertEqual($0 as? SealingError, .mismatch("request body uses reserved key p/t/c"))
            }
        }
        XCTAssertNoThrow(try WorkspaceEnvelope.plaintext(Reserved(), path: WorkspacePath.status, stamp: 1, channel: nil))
    }

    /// 明文是键排序、斜杠不转义的规范 JSON，与 `seal-fixtures.mjs` 的 `canonical()` 逐字节一致。
    func testEnvelopePlaintextIsCanonicalJSON() throws {
        let plaintext = try WorkspaceEnvelope.plaintext(WorkspaceRequest.Target(path: "/a/b"), path: WorkspacePath.fsMkdir,
                                                        stamp: 5, channel: "c")
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), #"{"c":"c","p":"/fs/mkdir","path":"/a/b","t":5}"#)
    }

    // MARK: - 密封样本（与 Kotlin 共用）

    private func sealedSample() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("sealed.json")) as? [String: Any])
    }

    private func fixtureSealer() throws -> Sealer {
        let root = Data((0..<32).map { UInt8($0) })
        return try Sealer(key: PairKey(root: root).derived(.remoteControl), nonce: Sealer.fixtureNonce)
    }

    private func canonicalBytes(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func testSealedRequestAndReplyMatchByteForByte() throws {
        let sample = try sealedSample()
        let sealer = try fixtureSealer()
        let agentId = try XCTUnwrap(sample["agentId"] as? String)
        let channel = try XCTUnwrap(sample["channel"] as? String)
        let stamp = try XCTUnwrap(sample["stamp"] as? Int64)
        XCTAssertEqual(stamp, 1_790_000_000_500)
        XCTAssertEqual(channel, "AAECAwQFBgcICQoLDA0ODw")

        // 请求：明文取自 request-write.json，密封后的 body.sealed 解开必须与 Swift 拼出的明文逐字节相同。
        let request = try XCTUnwrap(sample["request"] as? [String: Any])
        let requestPlain = try XCTUnwrap(request["plaintext"] as? NSObject)
        XCTAssertEqual(requestPlain, try JSONSerialization.jsonObject(with: fixture("request-write.json")) as? NSObject)
        let sealedRequest = try XCTUnwrap((request["body"] as? [String: Any])?["sealed"] as? String)
        let write = try JSONDecoder().decode(WorkspaceRequest.Write.self, from: fixture("request-write.json"))
        // 样本里的 `content` 是标准 base64（`+` `/`、带 `=` 补位），不是协议别处用的 base64url：电脑用 Foundation 的严格解码。
        XCTAssertEqual(write.content, "+/8=")
        XCTAssertEqual(Data(base64Encoded: write.content), Data([0xFB, 0xFF]))
        XCTAssertTrue(write.content.contains("+") && write.content.contains("/") && write.content.hasSuffix("="),
                      "样本要覆盖标准字母表的 `+` `/` 与补位")
        let expectedRequest = try WorkspaceEnvelope.plaintext(write, path: "/fs/write", stamp: stamp, channel: channel)
        let requestAAD = SealingContext.remoteControl(agentId: agentId)
        let openedRequest = try sealer.open(Sealed(text: sealedRequest), aad: requestAAD)
        XCTAssertEqual(openedRequest, expectedRequest)
        XCTAssertEqual(try sealer.seal(openedRequest, aad: requestAAD).text, sealedRequest, "重新密封要得到同一段密文")

        // 回复：钉在这一条请求上。
        let reply = try XCTUnwrap(sample["reply"] as? [String: Any])
        let sealedReply = try XCTUnwrap(reply["sealed"] as? String)
        let replyAAD = SealingContext.remoteControlResponse(agentId: agentId, channel: channel, stamp: stamp)
        let openedReply = try sealer.open(Sealed(text: sealedReply), aad: replyAAD)
        XCTAssertEqual(openedReply, try canonicalBytes(try XCTUnwrap(reply["plaintext"])))
        XCTAssertEqual(try sealer.seal(openedReply, aad: replyAAD).text, sealedReply)
        XCTAssertEqual(try WorkspaceReply.decode(WorkspaceFileStamp.self, from: openedReply),
                       WorkspaceFileStamp(mtimeMs: 1_790_000_000_999, size: 3))
        XCTAssertThrowsError(try sealer.open(Sealed(text: sealedReply), aad: requestAAD), "回复不能当请求解")
    }

    func testSealedReadStreamMatchesByteForByte() throws {
        let sample = try sealedSample()
        let sealer = try fixtureSealer()
        let agentId = try XCTUnwrap(sample["agentId"] as? String)
        let channel = try XCTUnwrap(sample["channel"] as? String)
        let stamp = try XCTUnwrap(sample["stamp"] as? Int64)
        let read = try XCTUnwrap(sample["read"] as? [String: Any])
        let parts = try XCTUnwrap(read["packets"] as? [[String: Any]])
        var buffer = try XCTUnwrap(Base64URL.decode(try XCTUnwrap(read["stream"] as? String)))

        let packets = try WorkspacePacket.drain(&buffer)
        XCTAssertEqual(packets.count, 3)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(parts.count, packets.count)

        for (index, packet) in packets.enumerated() {
            let kind = try XCTUnwrap(parts[index]["kind"] as? Int)
            let payload = try XCTUnwrap(Base64URL.decode(try XCTUnwrap(parts[index]["payload"] as? String)))
            let aad = SealingContext.remoteControlPacket(agentId: agentId, channel: channel, stamp: stamp, index: index)
            let opened = try sealer.openRaw(packet, aad: aad)
            XCTAssertEqual(opened, Data([UInt8(kind)]) + payload, "第 \(index) 个包")
            XCTAssertEqual(try sealer.sealRaw(opened, aad: aad), packet, "第 \(index) 个包重新密封要逐字节相同")
        }

        // 换序（拿第 1 个包按第 0 个的位置解）解不开。
        let first = SealingContext.remoteControlPacket(agentId: agentId, channel: channel, stamp: stamp, index: 0)
        XCTAssertThrowsError(try sealer.openRaw(packets[1], aad: first))

        // 三个包的内容是 header / data / end。
        let header = try JSONDecoder().decode(WorkspaceFileHeader.self,
                                              from: try XCTUnwrap(Base64URL.decode(try XCTUnwrap(parts[0]["payload"] as? String))))
        XCTAssertEqual(header, WorkspaceFileHeader(size: 6, mtimeMs: 1_790_000_000_123, contentType: "text/plain; charset=utf-8"))
        XCTAssertEqual(parts.compactMap { $0["kind"] as? Int },
                       [WorkspacePacket.Kind.header, .data, .end].map { Int($0.rawValue) })
    }

    func testTerminalListRoundTrips() throws {
        try assertRoundTrips(TerminalList.self, "term-list.json")
        let list = try JSONDecoder().decode(TerminalList.self, from: fixture("term-list.json"))
        XCTAssertNil(list.sessions[0].exited)
        XCTAssertEqual(list.sessions[1].exited?.code, 130)
        XCTAssertTrue(list.sessions.allSatisfy { TerminalCipher.isValidToken($0.id) })
    }

    func testTermCreateEnvelopeMatchesFixture() throws {
        let body = WorkspaceRequest.TermCreate(cwd: "/Users/me/Projects/demo", cols: 120, rows: 40)
        let produced = try WorkspaceEnvelope.plaintext(body, path: WorkspacePath.termCreate, stamp: 1_790_000_000_600,
                                                       channel: "AAECAwQFBgcICQoLDA0ODw")
        XCTAssertEqual(produced, try canonicalBytes(JSONSerialization.jsonObject(with: fixture("request-term-create.json"))))
    }

    /// 每次封之前把下一条要用的 nonce 放进去：样本里每条的 nonce 就是密文的第 1…12 字节。
    private final class NonceSlot: @unchecked Sendable {
        var next = Data()
    }

    func testSealedTerminalMessagesMatchByteForByte() throws {
        let sample = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("terminal.json")) as? [String: Any])
        let key = try PairKey(root: Data((0..<32).map { UInt8($0) })).derived(.remoteControl)
        let agentId = try XCTUnwrap(sample["agentId"] as? String)
        let sessionId = try XCTUnwrap(sample["sessionId"] as? String)
        let clientNonce = try XCTUnwrap(sample["clientNonce"] as? String)
        let serverNonce = try XCTUnwrap(sample["serverNonce"] as? String)
        let slot = NonceSlot()
        let provider: Sealer.NonceProvider = { _ in slot.next }
        var computer = try TerminalCipher(key: key, agentId: agentId, sessionId: sessionId, clientNonce: clientNonce,
                                          role: .computer, nonce: provider)
        var phone = try TerminalCipher(key: key, agentId: agentId, sessionId: sessionId, clientNonce: clientNonce,
                                       role: .phone, nonce: provider)

        let hello = try XCTUnwrap(sample["hello"] as? [String: String])
        let helloSealed = try XCTUnwrap(Base64URL.decode(try XCTUnwrap(hello["sealed"])))
        slot.next = helloSealed.subdata(in: 1..<13)
        XCTAssertEqual(try computer.sealHello(serverNonce: try XCTUnwrap(Base64URL.decode(serverNonce))), helloSealed,
                       "握手要逐字节相同")
        try phone.openHello(helloSealed)
        XCTAssertEqual(phone.serverNonce, serverNonce)
        XCTAssertEqual(TerminalFrame.plaintext(.hello(serverNonce: try XCTUnwrap(Base64URL.decode(serverNonce))), seq: 0),
                       try XCTUnwrap(Base64URL.decode(try XCTUnwrap(hello["plaintext"]))))

        let messages = try XCTUnwrap(sample["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 7)
        for (index, entry) in messages.enumerated() {
            let kind = UInt8(try XCTUnwrap(entry["kind"] as? Int))
            let payload = try XCTUnwrap(Base64URL.decode(try XCTUnwrap(entry["payload"] as? String)))
            let sealed = try XCTUnwrap(Base64URL.decode(try XCTUnwrap(entry["sealed"] as? String)))
            let message = try TerminalMessage.decode(kind: kind, payload: payload)
            slot.next = sealed.subdata(in: 1..<13)
            if entry["direction"] as? String == "m2c" {
                XCTAssertEqual(try computer.seal(message), sealed, "第 \(index) 条（电脑封）")
                XCTAssertEqual(try phone.open(sealed), message, "第 \(index) 条（手机解）")
            } else {
                XCTAssertEqual(try phone.seal(message), sealed, "第 \(index) 条（手机封）")
                XCTAssertEqual(try computer.open(sealed), message, "第 \(index) 条（电脑解）")
            }
        }

        // 换序：一条新连接的手机先收第二条电脑消息，序号对不上。
        var fresh = try TerminalCipher(key: key, agentId: agentId, sessionId: sessionId, clientNonce: clientNonce,
                                       role: .phone)
        try fresh.openHello(helloSealed)
        let second = try XCTUnwrap(Base64URL.decode(try XCTUnwrap(messages[1]["sealed"] as? String)))
        XCTAssertThrowsError(try fresh.open(second)) {
            XCTAssertEqual($0 as? TerminalWireError, .outOfOrder(expected: 0, got: 1))
        }
    }

    // MARK: - 语料对账

    /// `protocol-fixtures/workspace/` 不在顶层的覆盖对账里：这里单独对账，新增样本却没有用例会在这里暴露。
    func testWorkspaceFixtureDirectoryIsFullyCovered() throws {
        let dir = FixtureRoundTripTests.fixturesDir.appendingPathComponent("workspace")
        let onDisk = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") })
        let used: Set<String> = [
            "status-mac.json", "status-linux.json", "status-legacy.json", "listing.json",
            "failure-conflict.json", "failure-unknown-code.json", "request-write.json", "sealed.json",
            "terminal.json", "term-list.json", "request-term-create.json",
            "status-windows.json", "listing-drives.json", "listing-undecodable.json", "failure-no-trash.json",
        ]
        XCTAssertEqual(onDisk.subtracting(used).sorted(), [], "这些样本没有被任何用例使用")
        XCTAssertEqual(used.subtracting(onDisk).sorted(), [], "用例引用了不存在的样本")
    }

    // MARK: - 流式分包

    private func twoPacketWire() throws -> (first: Data, second: Data, wire: Data) {
        let sealer = Sealer(pairKey: .random(), purpose: .remoteControl)
        let first = try sealer.sealRaw(WorkspacePacket.plaintext(.header, Data("{}".utf8)), aad: "x:0")
        let second = try sealer.sealRaw(WorkspacePacket.plaintext(.data, Data([1, 2, 3])), aad: "x:1")
        return (first, second, WorkspacePacket.frame(first) + WorkspacePacket.frame(second))
    }

    /// 在每一个位置把线上字节切成两半（包括 4 字节长度头的中间）依次喂入，结果都一样。
    func testDrainSplitAtEveryOffset() throws {
        let (first, second, wire) = try twoPacketWire()
        for split in 0...wire.count {
            var buffer = Data()
            var packets: [Data] = []
            buffer.append(wire.prefix(split))
            packets += try WorkspacePacket.drain(&buffer)
            buffer.append(wire.dropFirst(split))
            packets += try WorkspacePacket.drain(&buffer)
            XCTAssertEqual(packets, [first, second], "在 \(split) 处切开")
            XCTAssertTrue(buffer.isEmpty, "在 \(split) 处切开")
        }
    }

    /// 调用方传进来的可能是别的 Data 的切片（起始下标不是 0）。
    func testDrainHandlesSliceWithNonZeroStartIndex() throws {
        let (first, second, wire) = try twoPacketWire()
        var buffer = (Data([9, 9, 9]) + wire).dropFirst(3)
        XCTAssertEqual(buffer.startIndex, 3)
        XCTAssertEqual(try WorkspacePacket.drain(&buffer), [first, second])
        XCTAssertTrue(buffer.isEmpty)

        // 只有半个包的切片：剩下的部分原样留在缓冲区里。
        var partial = (Data([7, 7]) + wire.prefix(10)).dropFirst(2)
        XCTAssertEqual(try WorkspacePacket.drain(&partial), [])
        XCTAssertEqual(partial, wire.prefix(10))
    }

    func testDrainRejectsBadLengthAfterValidPacket() throws {
        let (first, _, _) = try twoPacketWire()
        for badHeader: [UInt8] in [[0, 0, 0, 0], [0x7F, 0xFF, 0xFF, 0xFF], [0, 0x10, 0, 1]] {
            var buffer = WorkspacePacket.frame(first) + Data(badHeader)
            XCTAssertThrowsError(try WorkspacePacket.drain(&buffer), "\(badHeader)") {
                XCTAssertEqual($0 as? SealingError, .malformed)
            }
        }
    }
}
