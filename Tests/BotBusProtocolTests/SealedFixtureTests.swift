import Foundation
import XCTest
@testable import BotBusProtocol

/// 协议 3.0 的密封样本（`protocol-fixtures/` 顶层）与明文样本（`protocol-fixtures/plain/`）的对照。
///
/// 样本由 `scripts/seal-fixtures.mjs`（Node WebCrypto）用固定密钥与 `Sealer.fixtureNonce` 生成。这里用 CryptoKit 做三件事：
/// 1. 密封形状本身往返不变（和明文样本一样逐键比较）；
/// 2. 用同一把钥匙解开，结果与 `plain/` 里的明文逐键相等；
/// 3. 把明文重新密封，得到与样本逐键相同的 JSON——两种实现的密封格式、AAD、规范 JSON 完全一致。
/// Android、Windows 的实现照同一套样本做同样三件事即可证明兼容。
final class SealedFixtureTests: XCTestCase {
    /// 与 `seal-fixtures.mjs` 的 `FIXTURE_ROOT_KEY` 一致：0x00 … 0x1f。
    static let rootKey = try! PairKey(root: Data((0..<32).map { UInt8($0) }))
    static let agentId = "hV3nQ7pLxK2mR8sTfW4bZQ"
    // swift-crypto（Linux）的私钥类型不是 Sendable；测试里只读，不会跨线程改。
    nonisolated(unsafe) static let macPrivate = try! Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: Data(SHA256.hash(data: Data("botbus-fixture-mac-key".utf8))))
    nonisolated(unsafe) static let phonePrivate = try! Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: Data(SHA256.hash(data: Data("botbus-fixture-phone-key".utf8))))

    static let sealer = PairSealer(pairKey: rootKey, nonce: Sealer.fixtureNonce)

    /// 密封样本的种类按文件名前缀判定，与生成脚本同一规则。
    private enum Kind: CaseIterable { case snapshot, task, command, event, agentFrame, relayFrame, clientFrame }

    private static func kind(of name: String) -> Kind? {
        switch name {
        case "frame-agent-event.json": return .agentFrame
        case "frame-relay-command.json": return .relayFrame
        case "frame-client-snapshot.json": return .clientFrame
        default: break
        }
        if name.hasPrefix("snapshot") { return .snapshot }
        if name.hasPrefix("task-") { return .task }
        if name.hasPrefix("command-") { return .command }
        if name.hasPrefix("event-") { return .event }
        return nil
    }

    /// `plain/` 里每个可密封的样本在顶层都必须有密封版；两者都算作被覆盖。
    static var coveredNames: Set<String> {
        let plain = (try? FileManager.default.contentsOfDirectory(
            atPath: FixtureRoundTripTests.fixturesDir.appendingPathComponent("plain").path)) ?? []
        return Set(plain.filter { $0.hasSuffix(".json") && kind(of: $0) != nil })
    }

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: FixtureRoundTripTests.fixturesDir.appendingPathComponent(name))
    }

    private func json(_ data: Data) throws -> NSObject {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! NSObject
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try ProtocolJSON.decoder().decode(type, from: data(name))
    }

    private func assertJSONEqual<T: Encodable>(_ value: T, _ name: String, _ message: String,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try json(ProtocolJSON.encoder().encode(value)), try json(data(name)), message, file: file, line: line)
    }

    /// 往返、解开、重封三件事，对一种（密封类型, 明文类型）组合。
    private func check<S: Codable & Equatable, P: Codable & Equatable>(
        _ name: String, sealed: S.Type, plain: P.Type,
        open: (S) throws -> P, reseal: (P) throws -> S
    ) throws {
        let wire = try decode(S.self, name)
        try assertJSONEqual(wire, name, "\(name)：密封形状往返变了")
        let opened = try open(wire)
        try assertJSONEqual(opened, "plain/\(name)", "\(name)：解开后与 plain/ 不一致")
        XCTAssertEqual(opened, try decode(P.self, "plain/\(name)"), name)
        try assertJSONEqual(try reseal(opened), name, "\(name)：重新密封与样本不一致（两种实现的格式分叉了）")
    }

    func testEverySealedFixtureOpensToItsPlainTwinAndResealsIdentically() throws {
        let content = Self.sealer.content
        var checked = 0
        for name in Self.coveredNames.sorted() {
            switch Self.kind(of: name)! {
            case .snapshot:
                try check(name, sealed: SealedSnapshot.self, plain: Snapshot.self,
                          open: { try Snapshot(opening: $0, sealer: content) },
                          reseal: { try Self.relayView(SealedSnapshot(sealing: $0, sealer: content), of: $0) })
            case .task:
                try check(name, sealed: SealedTask.self, plain: TaskRecord.self,
                          open: { try TaskRecord(opening: $0, sealer: content) },
                          reseal: { try SealedTask(sealing: $0, sealer: content) })
            case .command:
                try check(name, sealed: SealedCommand.self, plain: Command.self,
                          open: { try Command(opening: $0, sealer: content) },
                          reseal: { try SealedCommand(sealing: $0, sealer: content) })
            case .event:
                try check(name, sealed: SealedEvent.self, plain: Event.self,
                          open: { try Event(opening: $0, sealer: Self.sealer) },
                          reseal: { try Self.relayView(SealedEvent(sealing: $0, agentId: Self.agentId, sealer: Self.sealer), of: $0) })
            case .agentFrame:
                try check(name, sealed: AgentFrame.self, plain: PlainAgentFrame.self,
                          open: { PlainAgentFrame(event: try Event(opening: $0.event, sealer: Self.sealer)) },
                          reseal: { AgentFrame(event: try SealedEvent(sealing: $0.event, agentId: Self.agentId, sealer: Self.sealer)) })
            case .relayFrame:
                try check(name, sealed: RelayFrame.self, plain: PlainRelayFrame.self,
                          open: { PlainRelayFrame(command: try Command(opening: $0.command, sealer: content)) },
                          reseal: { RelayFrame(command: try SealedCommand(sealing: $0.command, sealer: content)) })
            case .clientFrame:
                try check(name, sealed: ClientFrame.self, plain: PlainClientFrame.self,
                          open: { PlainClientFrame(snapshot: try Snapshot(opening: $0.snapshot!, sealer: content)) },
                          reseal: { snapshot in
                              ClientFrame(snapshot: try Self.relayView(SealedSnapshot(sealing: snapshot.snapshot, sealer: content),
                                                                       of: snapshot.snapshot)) })
            }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 40, "密封样本数量不对，生成脚本可能没跑")
    }

    /// Relay 自己造的「离线队列过期」结果没有密钥，只能是明文 error；合并快照里它就是这个样子。
    /// Mac 永远不会发这种结果，所以重封时按 Relay 的视角替换回去。
    private static func relayView(_ sealed: SealedSnapshot, of plain: Snapshot) -> SealedSnapshot {
        var view = sealed
        view.recentResults = zip(sealed.recentResults, plain.recentResults).map { sealedResult, result in
            guard !result.ok, result.error == "expired", result.taskId == nil, result.systemPermission == nil,
                  result.artifactId == nil else { return sealedResult }
            return SealedResult(commandId: result.commandId, finishedAt: result.finishedAt, error: "expired")
        }
        return view
    }

    private static func relayView(_ sealed: SealedEvent, of plain: Event) -> SealedEvent {
        guard sealed.kind == .snapshot, let snapshot = sealed.snapshot, let original = plain.snapshot else { return sealed }
        var view = sealed
        view.snapshot = relayView(snapshot, of: original)
        return view
    }

    // MARK: - 配对

    func testKeyEnvelopeOpensWithTheMacKeyAndReseals() throws {
        let envelope = try decode(KeyEnvelope.self, "key-envelope.json")
        XCTAssertEqual(try envelope.open(with: Self.macPrivate, agentId: Self.agentId), Self.rootKey)
        let resealed = try KeyEnvelope.seal(Self.rootKey, to: Self.macPrivate.publicKey, agentId: Self.agentId,
                                            ephemeral: Self.phonePrivate, nonce: Sealer.fixtureNonce)
        try assertJSONEqual(resealed, "key-envelope.json", "密钥信封与 Node 实现不一致")

        // 信封钉在 agentId 上：Relay 把它转给组里别的电脑也解不开。
        XCTAssertThrowsError(try envelope.open(with: Self.macPrivate, agentId: "Jc9dP1vNqY6gH0uEwS5tXo"))
        // 别的私钥解不开。
        XCTAssertThrowsError(try envelope.open(with: .init(), agentId: Self.agentId))
        // hello 帧里带的是同一个信封。
        XCTAssertEqual(try decode(RelayHelloFrame.self, "frame-relay-hello-with-key.json").keyEnvelope, envelope)
        XCTAssertEqual(try decode(PairClaimRequest.self, "relay-pair-claim-request.json").keyEnvelope, envelope)
        XCTAssertNil(try decode(PairClaimRequest.self, "relay-pair-claim-request-invite.json").keyEnvelope,
                     "邀请码认领不带信封：K 在 Mac 印的二维码里")
    }

    func testClientNamesAreSealed() throws {
        let clients = try decode(PairClientsResponse.self, "relay-pair-clients-response.json").clients
        let names = try clients.map { client in
            try client.sealedName.map { try Self.sealer.content.open(String.self, from: $0, aad: SealingContext.clientName) }
        }
        XCTAssertEqual(names, ["Demo 的 iPhone", "备用机", nil])
        let request = try decode(PairClaimRequest.self, "relay-pair-claim-request.json")
        XCTAssertEqual(request.sealedName, try Self.sealer.content.seal("Demo 的 iPhone", aad: SealingContext.clientName))
    }

    /// 推送注册与电脑侧设备表里的名字也是密文（同一个 AAD `client`），Relay 读不到哪台是「Demo 的 iPhone」。
    func testDeviceNamesAreSealed() throws {
        let content = Self.sealer.content
        func name(_ sealed: Sealed?) throws -> String? {
            try sealed.map { try content.open(String.self, from: $0, aad: SealingContext.clientName) }
        }
        XCTAssertEqual(try name(decode(DeviceRegistration.self, "relay-device-registration.json").sealedName), "Demo 的 iPhone")
        XCTAssertEqual(try name(decode(DeviceRegistration.self, "relay-device-registration-watch.json").sealedName),
                       "Demo 的 Apple Watch")
        let listed = try decode(AgentDevicesResponse.self, "relay-agent-devices-response.json")
        XCTAssertEqual(try listed.devices.map { try name($0.sealedName) }, ["Demo 的 iPhone", "Demo 的 Apple Watch", "旧 iPad", "Demo 的 Android"])
        XCTAssertEqual(try listed.clients.map { try name($0.sealedName) }, ["Demo 的 iPhone", "备用机", "Demo 的 Android"])
        XCTAssertEqual(listed.devices[0].clientId, listed.devices[1].clientId, "手表沿用配它的那台手机的凭据")
        XCTAssertNil(listed.devices[2].clientId)
        // 重封与样本逐字节一致（确定性 nonce）。
        XCTAssertEqual(try content.seal("Demo 的 Apple Watch", aad: SealingContext.clientName), listed.devices[1].sealedName)
    }

    // MARK: - 必须失败

    func testTamperingWrongKeyAndMovedCiphertextAllFail() throws {
        let task = try decode(SealedTask.self, "task-waiting-approval.json")
        let content = Self.sealer.content
        XCTAssertNoThrow(try TaskRecord(opening: task, sealer: content))

        // 改一个字节。
        var bytes = try XCTUnwrap(Base64URL.decode(task.sealed.text))
        bytes[bytes.count / 2] ^= 0x01
        var tampered = task
        tampered.sealed = Sealed(text: Base64URL.encode(bytes))
        XCTAssertThrowsError(try TaskRecord(opening: tampered, sealer: content)) { XCTAssertEqual($0 as? SealingError, .cannotOpen) }

        // 挪到别的任务 id / 别的电脑下：AAD 对不上。
        var moved = task
        moved.id = "codex:someone-else"
        XCTAssertThrowsError(try TaskRecord(opening: moved, sealer: content))
        moved = task
        moved.agentId = "Jc9dP1vNqY6gH0uEwS5tXo"
        XCTAssertThrowsError(try TaskRecord(opening: moved, sealer: content))

        // 改信封外面的 updatedAt（Relay 按它排序）：密文照样能解，但与明文对不上。
        var reordered = task
        reordered.updatedAt = "2099-01-01T00:00:00Z"
        XCTAssertThrowsError(try TaskRecord(opening: reordered, sealer: content)) {
            XCTAssertEqual($0 as? SealingError, .mismatch("updatedAt"))
        }

        // 错钥匙。
        let other = Sealer(pairKey: .random())
        XCTAssertThrowsError(try TaskRecord(opening: task, sealer: other))

        // 推送用的是另一把派生钥匙：内容钥匙解不开推送，反之亦然。
        let notify = try decode(SealedEvent.self, "event-notify.json").notify!
        XCTAssertNoThrow(try Notify(opening: notify, sealer: Self.sealer.notify))
        XCTAssertThrowsError(try Notify(opening: notify, sealer: content))

        // 不认识的格式版本、太短的信封。
        var future = try XCTUnwrap(Base64URL.decode(task.sealed.text))
        future[future.startIndex] = 0x02
        XCTAssertThrowsError(try content.open(Sealed(text: Base64URL.encode(future)), aad: "x")) {
            XCTAssertEqual($0 as? SealingError, .unsupportedVersion(0x02))
        }
        XCTAssertThrowsError(try content.open(Sealed(text: "AQ"), aad: "x")) { XCTAssertEqual($0 as? SealingError, .malformed) }
    }

    func testRandomNonceDiffersEveryTime() throws {
        let sealer = Sealer(pairKey: Self.rootKey)
        let a = try sealer.seal(Data("same".utf8), aad: "x")
        let b = try sealer.seal(Data("same".utf8), aad: "x")
        XCTAssertNotEqual(a, b, "生产环境的 nonce 必须随机")
        XCTAssertEqual(try sealer.open(a, aad: "x"), Data("same".utf8))
    }

    func testDerivedKeysAndArtifactIdsAreStable() throws {
        let key = Self.rootKey
        XCTAssertEqual(Set(PairKey.Purpose.allCases.map { key.derived($0) }).count, PairKey.Purpose.allCases.count)
        XCTAssertEqual(key.fingerprint.count, 8)
        let id = key.artifactId(for: Data("图片字节".utf8))
        XCTAssertEqual(id.count, 22)
        XCTAssertEqual(id, key.artifactId(for: Data("图片字节".utf8)))
        XCTAssertNotEqual(id, PairKey.random().artifactId(for: Data("图片字节".utf8)), "换了组就对不上")
        XCTAssertEqual(PairKey(base64url: key.base64url), key)
        XCTAssertNil(PairKey(base64url: "short"))
    }

    /// Mac 与客户端的完整往返：Mac 密封全量快照 → （Relay 原样存取）→ 客户端解开，与原快照相等。
    func testSnapshotSurvivesSealAndOpenWithRandomNonces() throws {
        let sealer = PairSealer(pairKey: .random())
        let snapshot = try ProtocolJSON.decoder().decode(Snapshot.self, from: data("plain/snapshot-multi-agent.json"))
        let wire = try SealedSnapshot(sealing: snapshot, sealer: sealer.content)
        let roundTripped = try ProtocolJSON.decoder().decode(SealedSnapshot.self, from: ProtocolJSON.encoder().encode(wire))
        XCTAssertEqual(try Snapshot(opening: roundTripped, sealer: sealer.content), snapshot)
    }

    /// 线上 JSON 里不能出现任何明文内容：拿 plain/ 里的标题与 prompt 在密封样本里搜。
    func testSealedFixturesLeakNoContent() throws {
        let snapshot = String(decoding: try data("snapshot.json"), as: UTF8.self)
        let plain = try ProtocolJSON.decoder().decode(Snapshot.self, from: data("plain/snapshot.json"))
        for task in plain.tasks {
            XCTAssertFalse(snapshot.contains(task.title), task.title)
            XCTAssertFalse(snapshot.contains(task.projectPath), task.projectPath)
        }
        for agent in plain.agents { XCTAssertFalse(snapshot.contains(agent.name), agent.name) }
        let command = String(decoding: try data("command-start-task.json"), as: UTF8.self)
        let prompt = try ProtocolJSON.decoder().decode(Command.self, from: data("plain/command-start-task.json")).startTask!.prompt
        XCTAssertFalse(command.contains(prompt))
        XCTAssertFalse(command.contains("startTask"), "命令种类也在密文里")
    }
}

// 明文帧只在测试里用来对照 `plain/frame-*.json`：线上只有密封帧。
private struct PlainAgentFrame: Codable, Equatable {
    var type = "event"
    var event: Event
}

private struct PlainRelayFrame: Codable, Equatable {
    var type = "command"
    var command: Command
}

private struct PlainClientFrame: Codable, Equatable {
    var type = "snapshot"
    var snapshot: Snapshot
}
