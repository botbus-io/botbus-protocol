import Foundation
import XCTest
import BotBusProtocol

/// 语料里的一条：fixture 名 + 对它的校验动作。
/// 各用例与 `testFixtureCorpusIsFullyCovered` 共用同一张表，新增 fixture 却忘了写用例会在对账里暴露。
private typealias FixtureCase = (name: String, run: (FixtureRoundTripTests) throws -> Void)

private func roundTripCase<T: Codable & Equatable>(_ type: T.Type, _ name: String) -> FixtureCase {
    (name, { try $0.roundTrip(type, name) })
}

final class FixtureRoundTripTests: XCTestCase {
    /// 从本文件路径向上找到仓库根目录下的 protocol-fixtures。
    static let fixturesDir: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("protocol-fixtures")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            url.deleteLastPathComponent()
        }
        fatalError("protocol-fixtures not found above \(#filePath)")
    }()

    fileprivate func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixturesDir.appendingPathComponent(name))
    }

    fileprivate func decodeFixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try ProtocolJSON.decoder().decode(type, from: fixture(name))
    }

    /// 编码 → 与原 JSON 逐键比较 → 再解码 → 与原值相等。
    fileprivate func assertRoundTrips<T: Codable & Equatable>(_ value: T, _ name: String) throws {
        let reencoded = try ProtocolJSON.encoder().encode(value)
        let original = try JSONSerialization.jsonObject(with: fixture(name)) as! NSObject
        let produced = try JSONSerialization.jsonObject(with: reencoded) as! NSObject
        XCTAssertEqual(original, produced, "round trip changed JSON for \(name)")
        let again = try ProtocolJSON.decoder().decode(T.self, from: reencoded)
        XCTAssertEqual(value, again, "second decode differs for \(name)")
    }

    /// 解码 → 编码 → 与原 JSON 逐键比较 → 再解码 → 与首次解码结果相等。
    fileprivate func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ name: String) throws {
        try assertRoundTrips(decodeFixture(type, name), name)
    }

    private func run(_ cases: [FixtureCase]) throws {
        for fixtureCase in cases { try fixtureCase.run(self) }
    }

    // MARK: - 语料清单

    private static var snapshotCases: [FixtureCase] { [
        roundTripCase(Snapshot.self, "plain/snapshot.json"),
        roundTripCase(Snapshot.self, "plain/snapshot-client.json"),
        roundTripCase(Snapshot.self, "plain/snapshot-multi-agent.json"),
        roundTripCase(Snapshot.self, "plain/snapshot-hermes-pi-openclaw.json"),
        roundTripCase(Snapshot.self, "plain/snapshot-dsh.json"),
        roundTripCase(Snapshot.self, "plain/snapshot-auto-approve.json"),
    ] }

    private static var taskCases: [FixtureCase] { [
        roundTripCase(TaskRecord.self, "plain/task-waiting-approval.json"),
        roundTripCase(TaskRecord.self, "plain/task-waiting-approval-choices.json"),
        roundTripCase(TaskRecord.self, "plain/task-waiting-input.json"),
        roundTripCase(TaskRecord.self, "plain/task-waiting-input-questions.json"),
        roundTripCase(TaskRecord.self, "plain/task-with-artifacts.json"),
        roundTripCase(TaskRecord.self, "plain/task-outside-project.json"),
        roundTripCase(TaskRecord.self, "plain/task-in-worktree.json"),
        roundTripCase(TaskRecord.self, "plain/task-with-system-permission.json"),
        roundTripCase(TaskRecord.self, "plain/task-acp.json"),
        roundTripCase(TaskRecord.self, "plain/task-with-model.json"),
    ] }

    private static var artifactCases: [FixtureCase] { [
        roundTripCase(Artifact.self, "plain/artifact-image.json"),
        roundTripCase(Artifact.self, "plain/artifact-video.json"),
    ] }

    private static var commandCases: [FixtureCase] { [
        roundTripCase(Command.self, "plain/command-start-task.json"),
        roundTripCase(Command.self, "plain/command-start-task-outside-project.json"),
        roundTripCase(Command.self, "plain/command-start-task-new-project.json"),
        roundTripCase(Command.self, "plain/command-follow-up.json"),
        roundTripCase(Command.self, "plain/command-follow-up-with-attachments.json"),
        roundTripCase(Command.self, "plain/command-follow-up-model.json"),
        roundTripCase(Command.self, "plain/command-start-task-model.json"),
        roundTripCase(Command.self, "plain/command-follow-up-auto-approve.json"),
        roundTripCase(Command.self, "plain/command-start-task-auto-approve.json"),
        roundTripCase(Command.self, "plain/command-approve.json"),
        roundTripCase(Command.self, "plain/command-approve-deny.json"),
        roundTripCase(Command.self, "plain/command-approve-answers.json"),
        roundTripCase(Command.self, "plain/command-interrupt.json"),
        roundTripCase(Command.self, "plain/command-set-connector-enabled.json"),
        roundTripCase(Command.self, "plain/command-fetch-messages.json"),
        roundTripCase(Command.self, "plain/command-fetch-file.json"),
        roundTripCase(Command.self, "plain/command-fetch-changes.json"),
        roundTripCase(Command.self, "plain/command-remote-control.json"),
        roundTripCase(Command.self, "plain/command-start-task-acp.json"),
        roundTripCase(Command.self, "plain/command-set-connector-enabled-acp.json"),
    ] }

    private static var eventCases: [FixtureCase] { [
        roundTripCase(Event.self, "plain/event-snapshot.json"),
        roundTripCase(Event.self, "plain/event-task-updated.json"),
        roundTripCase(Event.self, "plain/event-task-removed.json"),
        roundTripCase(Event.self, "plain/event-command-result.json"),
        roundTripCase(Event.self, "plain/event-command-result-system-permission.json"),
        roundTripCase(Event.self, "plain/event-command-result-changes.json"),
        roundTripCase(Event.self, "plain/event-notify.json"),
        roundTripCase(Event.self, "plain/event-notify-done.json"),
        roundTripCase(Event.self, "plain/event-notify-input.json"),
        roundTripCase(Event.self, "plain/event-notify-failed.json"),
        roundTripCase(Event.self, "plain/event-task-messages.json"),
        roundTripCase(Event.self, "plain/event-task-messages-with-attachments.json"),
    ] }

    private static var frameCases: [FixtureCase] { [
        roundTripCase(RelayHelloFrame.self, "frame-relay-hello.json"),
        roundTripCase(RelayHelloFrame.self, "frame-relay-hello-with-key.json"),
        roundTripCase(ClientFrame.self, "frame-client-changed.json"),
    ] }

    private static var changesCases: [FixtureCase] { [
        roundTripCase(WorkingChanges.self, "plain/working-changes.json"),
    ] }

    private static var agentCases: [FixtureCase] { [
        roundTripCase(AgentInfo.self, "plain/agent-info.json"),
        roundTripCase(ConnectorInfo.self, "plain/connector-info-unavailable.json"),
        roundTripCase(AgentInfo.self, "plain/agent-info-acp.json"),
        roundTripCase(AgentInfo.self, "plain/agent-info-models.json"),
    ] }

    private static var relayCases: [FixtureCase] { [
        roundTripCase(AgentRegisterResponse.self, "relay-agent-register-response.json"),
        roundTripCase(PairClaimRequest.self, "relay-pair-claim-request.json"),
        roundTripCase(PairClaimRequest.self, "relay-pair-claim-request-invite.json"),
        roundTripCase(KeyEnvelope.self, "key-envelope.json"),
        roundTripCase(PairClaimResponse.self, "relay-pair-claim-response.json"),
        roundTripCase(PairAgentsResponse.self, "relay-pair-agents-response.json"),
        roundTripCase(AgentInviteResponse.self, "relay-agent-invite-response.json"),
        roundTripCase(PairClientsResponse.self, "relay-pair-clients-response.json"),
        roundTripCase(AgentDevicesResponse.self, "relay-agent-devices-response.json"),
        roundTripCase(DeviceRegistration.self, "relay-device-registration.json"),
        roundTripCase(DeviceRegistration.self, "relay-device-registration-watch.json"),
        roundTripCase(DeviceRegistration.self, "relay-device-registration-android.json"),
        roundTripCase(CommandAccepted.self, "relay-command-accepted.json"),
        roundTripCase(ArtifactUploadResponse.self, "relay-artifact-upload-response.json"),
        roundTripCase(PreviewCreateRequest.self, "relay-preview-create-request.json"),
        roundTripCase(PreviewCreateResponse.self, "relay-preview-create-response.json"),
        roundTripCase(PreviewSessionResponse.self, "relay-preview-session-response.json"),
    ] }

    /// invalid 下的每个样本都有一条自己的用例（见下），这里只用于语料对账。
    private static let invalidFixtureNames = [
        "plain/invalid/task-bad-status.json",
        "plain/invalid/command-payload-mismatch.json",
        "invalid/command-missing-agent-id.json",
        "invalid/event-payload-mismatch.json",
        "plain/invalid/pending-request-bad-kind.json",
        "plain/invalid/pending-question-missing-options.json",
        "plain/invalid/agent-info-bad-connector-kind.json",
        "plain/invalid/artifact-bad-kind.json",
        "invalid/client-frame-payload-mismatch.json",
        "plain/invalid/event-system-permission-missing-dialog-text.json",
        "plain/invalid/task-acp-missing-connector-id.json",
        "plain/invalid/agent-info-acp-missing-connector-id.json",
        "plain/invalid/agent-info-duplicate-acp-connector.json",
        "plain/invalid/command-start-task-acp-missing-connector-id.json",
        "plain/invalid/command-follow-up-bad-model.json",
        "plain/invalid/command-start-task-bad-effort.json",
        "plain/invalid/connector-info-effort-not-listed.json",
    ]

    // MARK: - 往返

    func testSnapshots() throws {
        try run(Self.snapshotCases)
    }

    func testTasks() throws {
        try run(Self.taskCases)
    }

    func testArtifacts() throws {
        try run(Self.artifactCases)
    }

    func testSystemPermissionSurvivesSnapshotAndKeepsOptionalFieldsOmitted() throws {
        let task = try decodeFixture(TaskRecord.self, "plain/task-with-system-permission.json")
        let result = try XCTUnwrap(decodeFixture(Event.self, "plain/event-command-result-system-permission.json").commandResult)
        XCTAssertEqual(task.systemPermission?.screenshot?.kind, .image)
        XCTAssertNotNil(task.systemPermission?.screenshot?.expiresAt)
        XCTAssertNil(result.taskId, "任务创建失败也能返回系统授权提示")
        XCTAssertNil(result.systemPermission?.screenshot, "无法截图时仍保留弹窗文字")

        var snapshot = try decodeFixture(Snapshot.self, "plain/snapshot.json")
        snapshot.tasks.insert(task, at: 0)
        snapshot.recentResults = [result]
        let decoded = try ProtocolJSON.decoder().decode(Snapshot.self, from: ProtocolJSON.encoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertNil(decoded.tasks[1].systemPermission, "旧任务缺少该键时兼容解码")

        let notice = SystemPermissionNotice(id: "notice", detectedAt: result.finishedAt, dialogText: "Allow access?")
        let noticeJSON = try JSONSerialization.jsonObject(with: ProtocolJSON.encoder().encode(notice)) as! [String: Any]
        XCTAssertFalse(noticeJSON.keys.contains("screenshot"))
        let plainResult = CommandResult(commandId: "plain", ok: false, finishedAt: result.finishedAt)
        let plainJSON = try JSONSerialization.jsonObject(with: ProtocolJSON.encoder().encode(plainResult)) as! [String: Any]
        XCTAssertFalse(plainJSON.keys.contains("systemPermission"))
    }

    func testCommands() throws {
        try run(Self.commandCases)
    }

    func testEvents() throws {
        try run(Self.eventCases)
    }

    func testFrames() throws {
        try run(Self.frameCases)
    }

    func testRelayMessages() throws {
        try run(Self.relayCases)
    }

    func testAgentInfoRoundTrip() throws {
        let info = try decodeFixture(AgentInfo.self, "plain/agent-info.json")
        XCTAssertEqual(info.connectors.count, 2)
        XCTAssertEqual(info.connectors[0].kind, .codex)
        XCTAssertTrue(info.connectors[0].available)
        XCTAssertFalse(info.connectors[1].available)
        XCTAssertEqual(info.platform, .macos)

        let unavailable = try decodeFixture(ConnectorInfo.self, "plain/connector-info-unavailable.json")
        XCTAssertEqual(unavailable.kind, .claude)
        XCTAssertFalse(unavailable.enabled)
        XCTAssertEqual(unavailable.status, .degraded)
        XCTAssertEqual(unavailable.taskCount, 0)
        XCTAssertNil(unavailable.lastError)

        try run(Self.agentCases)
    }

    func testWorkingChanges() throws {
        try run(Self.changesCases)
        let changes = try decodeFixture(WorkingChanges.self, "plain/working-changes.json")
        XCTAssertEqual(changes.files.map(\.path), changes.files.map(\.path).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) },
                       "按路径的字节序排")
        XCTAssertNil(changes.files.first { $0.binary == true }?.patch, "二进制文件不带 diff")
        let result = try XCTUnwrap(decodeFixture(Event.self, "plain/event-command-result-changes.json").commandResult)
        XCTAssertEqual(result.artifactId, "Xk2mR8sTfW4bZQhV3nQ7pL")
        let plain = CommandResult(commandId: "plain", ok: true, finishedAt: result.finishedAt)
        let json = try JSONSerialization.jsonObject(with: ProtocolJSON.encoder().encode(plain)) as! [String: Any]
        XCTAssertFalse(json.keys.contains("artifactId"), "别的命令的结果不带这个键")
    }

    func testMultiAgentSnapshotGroupsTasksByAgent() throws {
        let snapshot = try decodeFixture(Snapshot.self, "plain/snapshot-multi-agent.json")
        XCTAssertEqual(snapshot.agents.count, 2)
        XCTAssertEqual(Set(snapshot.tasks.map(\.agentId)).count, 2)
        XCTAssertTrue(snapshot.tasks.allSatisfy { task in snapshot.agents.contains { $0.agentId == task.agentId } })
        XCTAssertTrue(snapshot.projects.allSatisfy { project in snapshot.agents.contains { $0.agentId == project.agentId } })
        XCTAssertFalse(snapshot.agents[1].online)
    }

    func testSetConnectorEnabledCommand() throws {
        let command = try decodeFixture(Command.self, "plain/command-set-connector-enabled.json")
        XCTAssertEqual(command.kind, .setConnectorEnabled)
        XCTAssertEqual(command.setConnectorEnabled?.connector, .codex)
        XCTAssertEqual(command.setConnectorEnabled?.enabled, false)
        XCTAssertFalse(command.agentId.isEmpty)
        XCTAssertNil(command.interrupt)

        let built = Command.setConnectorEnabled(.init(connector: .claude, enabled: true),
                                                createdAt: "2026-09-17T08:25:00Z",
                                                id: "5e4d3c2b-1a09-4f8e-8d7c-6b5a49382716",
                                                agentId: command.agentId)
        XCTAssertEqual(built.kind, .setConnectorEnabled)
        XCTAssertEqual(built.setConnectorEnabled?.connector, .claude)
        XCTAssertEqual(built.agentId, command.agentId)
    }

    /// 编码方向同样受"kind 与载荷必须匹配"的约束：缺载荷直接拒绝编码，多余载荷不会被写出。
    func testCommandPayloadRuleAppliesWhenEncoding() throws {
        let missing = Command(id: "1e1e1e1e-0000-4000-8000-000000000001",
                              createdAt: "2026-09-17T08:25:00Z",
                              agentId: "hV3nQ7pLxK2mR8sTfW4bZQ",
                              kind: .setConnectorEnabled)
        XCTAssertThrowsError(try ProtocolJSON.encoder().encode(missing))

        let extra = Command(id: "1e1e1e1e-0000-4000-8000-000000000002",
                            createdAt: "2026-09-17T08:25:00Z",
                            agentId: "hV3nQ7pLxK2mR8sTfW4bZQ",
                            kind: .interrupt,
                            interrupt: .init(taskId: "codex:01a0ab79-8c36-7011-bda3-10587db84466"),
                            setConnectorEnabled: .init(connector: .codex, enabled: true))
        let encoded = try JSONSerialization.jsonObject(with: ProtocolJSON.encoder().encode(extra)) as! [String: Any]
        XCTAssertNil(encoded["setConnectorEnabled"], "与 kind 不符的载荷不应出现在编码结果里")
        XCTAssertNotNil(encoded["interrupt"])
        XCTAssertEqual(encoded["agentId"] as? String, "hV3nQ7pLxK2mR8sTfW4bZQ")
    }

    // MARK: - 拒绝

    func testSystemPermissionWithoutDialogTextIsRejected() throws {
        XCTAssertThrowsError(try decodeFixture(Event.self, "plain/invalid/event-system-permission-missing-dialog-text.json"))
    }

    func testInvalidStatusIsRejected() throws {
        XCTAssertThrowsError(try decodeFixture(TaskRecord.self, "plain/invalid/task-bad-status.json"))
    }

    func testCommandPayloadMismatchIsRejected() throws {
        XCTAssertThrowsError(try decodeFixture(Command.self, "plain/invalid/command-payload-mismatch.json"))
    }

    func testPendingRequestBadKindIsRejected() throws {
        XCTAssertThrowsError(try decodeFixture(TaskRecord.self, "plain/invalid/pending-request-bad-kind.json"))
    }

    func testQuestionWithoutOptionsIsRejected() throws {
        XCTAssertThrowsError(try decodeFixture(TaskRecord.self, "plain/invalid/pending-question-missing-options.json"))
    }

    /// 2.14：单选省略 `multiSelect`，旧样本（没有 questions / answers）照常解码。
    func testQuestionsKeepSingleSelectOmittedAndOldSamplesDecode() throws {
        let task = try decodeFixture(TaskRecord.self, "plain/task-waiting-input-questions.json")
        let questions = try XCTUnwrap(task.pendingRequest?.questions)
        XCTAssertEqual(questions.map(\.allowsMultiple), [false, true])
        let single = PendingQuestion(id: "0", question: "Q", options: [PendingOption(label: "A")])
        let json = try JSONSerialization.jsonObject(with: ProtocolJSON.encoder().encode(single)) as! [String: Any]
        XCTAssertFalse(json.keys.contains("multiSelect"))
        XCTAssertFalse(json.keys.contains("header"))

        XCTAssertNil(try decodeFixture(TaskRecord.self, "plain/task-waiting-input.json").pendingRequest?.questions)
        XCTAssertNil(try decodeFixture(Command.self, "plain/command-approve.json").approve?.answers)
        XCTAssertEqual(try decodeFixture(Command.self, "plain/command-approve-answers.json").approve?.answers?["1"], ["手机", "手表"])
    }

    func testEventPayloadMismatchIsRejected() throws {
        XCTAssertThrowsError(try decodeFixture(Event.self, "invalid/event-payload-mismatch.json"))
    }

    func testCommandWithoutAgentIdIsRejected() {
        XCTAssertThrowsError(try decodeFixture(Command.self, "invalid/command-missing-agent-id.json"))
    }

    /// 协议 v2.2 之前的 Relay 不发 `recentMessages`。缺了它整份快照都解不出来的话，
    /// 客户端会卡在"正在加载"——上线那天就撞过一次，这条把它钉住。
    func testSnapshotWithoutRecentMessagesStillDecodes() throws {
        let v21 = Data("""
        {"agents":[],"tasks":[],"projects":[],"recentResults":[],"seq":3,
         "generatedAt":"2026-09-20T21:00:00Z"}
        """.utf8)
        let snapshot = try ProtocolJSON.decoder().decode(Snapshot.self, from: v21)
        XCTAssertEqual(snapshot.seq, 3)
        XCTAssertTrue(snapshot.recentMessages.isEmpty)
    }

    func testUnknownArtifactKindIsRejected() throws {
        XCTAssertThrowsError(try decodeFixture(Artifact.self, "plain/invalid/artifact-bad-kind.json"))
        // 未知 kind 挂在任务上时，整条任务同样被拒绝，不会静默当成别的 kind。
        var task = try JSONSerialization.jsonObject(with: fixture("plain/task-with-artifacts.json")) as! [String: Any]
        task["artifacts"] = [try JSONSerialization.jsonObject(with: fixture("plain/invalid/artifact-bad-kind.json"))]
        let data = try JSONSerialization.data(withJSONObject: task)
        XCTAssertThrowsError(try ProtocolJSON.decoder().decode(TaskRecord.self, from: data))
    }

    func testClientFrameWithoutPayloadForTypeIsRejected() throws {
        XCTAssertThrowsError(try decodeFixture(ClientFrame.self, "invalid/client-frame-payload-mismatch.json"))
    }

    /// 协议 2.13：`connectorId` 只跟 `acp` 一起出现且必须出现，同一台电脑上不能有两个相同的 `(kind, connectorId)`。
    func testAcpFieldsAreValidated() throws {
        XCTAssertThrowsError(try decodeFixture(TaskRecord.self, "plain/invalid/task-acp-missing-connector-id.json"))
        XCTAssertThrowsError(try decodeFixture(AgentInfo.self, "plain/invalid/agent-info-acp-missing-connector-id.json"))
        XCTAssertThrowsError(try decodeFixture(AgentInfo.self, "plain/invalid/agent-info-duplicate-acp-connector.json"))
        XCTAssertThrowsError(try decodeFixture(Command.self, "plain/invalid/command-start-task-acp-missing-connector-id.json"))

        let info = try decodeFixture(AgentInfo.self, "plain/agent-info-acp.json")
        XCTAssertEqual(info.connectors.map(\.ref), [ConnectorRef(kind: .codex), .acp("gemini"), .acp("my-agent")])
        XCTAssertEqual(info.connectors[2].canStartTask, false)
        XCTAssertNil(info.connectors[1].canStartTask)
    }

    /// 协议 3.2：模型 id 会成为 agent 命令行的参数值，不能以 `-` 开头；默认强度必须在可选强度里。
    func testModelFieldsAreValidated() throws {
        XCTAssertThrowsError(try decodeFixture(Command.self, "plain/invalid/command-follow-up-bad-model.json"))
        XCTAssertThrowsError(try decodeFixture(ConnectorInfo.self, "plain/invalid/connector-info-effort-not-listed.json"))

        let info = try decodeFixture(AgentInfo.self, "plain/agent-info-models.json")
        XCTAssertEqual(info.connectors[0].models?.first?.defaultEffort, "medium")
        XCTAssertNil(info.connectors[1].models?.last?.efforts, "不能调强度的模型整个键省略")
        let followUp = try XCTUnwrap(decodeFixture(Command.self, "plain/command-follow-up-model.json").followUp)
        XCTAssertEqual(followUp.model, "gpt-5.5")
        XCTAssertEqual(followUp.effort, "xhigh")
        XCTAssertNil(try XCTUnwrap(decodeFixture(Command.self, "plain/command-follow-up.json").followUp).model)
        XCTAssertThrowsError(try decodeFixture(Command.self, "plain/invalid/command-start-task-bad-effort.json"))
        let start = try XCTUnwrap(decodeFixture(Command.self, "plain/command-start-task-model.json").startTask)
        XCTAssertEqual(start.model, "opus")
        XCTAssertEqual(start.effort, "high")
        XCTAssertNil(try XCTUnwrap(decodeFixture(Command.self, "plain/command-start-task.json").startTask).model)

        XCTAssertTrue(ModelOption.isValidId("claude-opus-5-5"))
        XCTAssertTrue(ModelOption.isValidId("openrouter/gpt-5.5:free"))
        XCTAssertFalse(ModelOption.isValidId("-p"))
        XCTAssertFalse(ModelOption.isValidId("opus[1m]"))
        XCTAssertFalse(ModelOption.isValidId(""))
        XCTAssertFalse(ModelOption.isValidEffort("High"))
        XCTAssertTrue(ModelOption.isValidEffort("xhigh"))
    }

    /// 协议 3.3：项目级自动批准。能力与状态都只写 true（没有时整键省略）；命令里 true / false 都有意义。
    func testAutoApproveFields() throws {
        let snapshot = try decodeFixture(Snapshot.self, "plain/snapshot-auto-approve.json")
        XCTAssertEqual(snapshot.agents[0].connectors[0].canAutoApprove, true)
        XCTAssertNil(snapshot.agents[0].connectors[1].canAutoApprove)
        XCTAssertEqual(snapshot.projects[0].autoApprove, true)
        XCTAssertNil(snapshot.projects[1].autoApprove)
        XCTAssertEqual(snapshot.tasks[0].autoApprove, true)

        let followUp = try XCTUnwrap(decodeFixture(Command.self, "plain/command-follow-up-auto-approve.json").followUp)
        XCTAssertEqual(followUp.autoApprove, false, "false 是明确关掉，不是省略")
        let start = try XCTUnwrap(decodeFixture(Command.self, "plain/command-start-task-auto-approve.json").startTask)
        XCTAssertEqual(start.autoApprove, true)
        XCTAssertNil(try XCTUnwrap(decodeFixture(Command.self, "plain/command-follow-up.json").followUp).autoApprove)
    }

    /// 旧版 Agent 只认 `RelayFrame`：hello 帧在它那里必须解码失败（被忽略），而不是被误读成命令。
    func testHelloFrameIsNotARelayFrame() throws {
        XCTAssertThrowsError(try decodeFixture(RelayFrame.self, "frame-relay-hello.json"))
        XCTAssertEqual(try decodeFixture(RelayHelloFrame.self, "frame-relay-hello.json").pairId, "pR4dT9wKmZ2xL7vQn3sB8A")
    }

    // MARK: - 协议 2.3：任务产物

    func testTaskWithArtifactsKeepsNewestFirst() throws {
        let task = try decodeFixture(TaskRecord.self, "plain/task-with-artifacts.json")
        let artifacts = try XCTUnwrap(task.artifacts)
        XCTAssertEqual(artifacts.map(\.kind), [.preview, .image, .file, .link], "fixture 应四种 kind 各一")
        XCTAssertLessThanOrEqual(artifacts.count, TaskRecord.maxArtifacts)
        XCTAssertEqual(artifacts.map(\.createdAt), artifacts.map(\.createdAt).sorted(by: >), "产物新的在前")
        XCTAssertEqual(artifacts[0].port, 5173)
        XCTAssertNil(artifacts[2].expiresAt)
        XCTAssertNil(artifacts[3].size)
    }

    /// 2.3 之前的对端不发 `artifacts`。缺了它任务必须照常解码，且再编码时不凭空冒出这个键（也不写 null）。
    func testTaskWithoutArtifactsStillDecodes() throws {
        let task = try decodeFixture(TaskRecord.self, "plain/task-waiting-approval.json")
        XCTAssertNil(task.artifacts)
        let encoded = try JSONSerialization.jsonObject(with: ProtocolJSON.encoder().encode(task)) as! [String: Any]
        XCTAssertFalse(encoded.keys.contains("artifacts"))
    }

    /// "某 kind 必填某字段"由生产方保证，消费方不拒绝：缺了 contentType / size 的 image 照样能解码。
    func testArtifactKindSpecificFieldsAreNotEnforcedOnDecode() throws {
        let bare = Data(#"{"id":"tZgTTkmbwO5T8u5vDlzw2g","kind":"image","title":"截图","createdAt":"2026-09-24T09:30:00Z"}"#.utf8)
        let artifact = try ProtocolJSON.decoder().decode(Artifact.self, from: bare)
        XCTAssertNil(artifact.contentType)
        XCTAssertNil(artifact.size)
        XCTAssertThrowsError(try ProtocolJSON.decoder().decode(Artifact.self, from: Data(
            #"{"id":"a","kind":"image","title":"t","createdAt":"2026-09-24T09:30:00Z","size":1.5}"#.utf8)),
            "size 必须是整数")
    }

    /// 带产物的任务放进快照（Agent 分片与客户端合并快照都是这个形状）后往返不变。
    func testSnapshotWithArtifactTaskRoundTrips() throws {
        var snapshot = try decodeFixture(Snapshot.self, "plain/snapshot.json")
        let task = try decodeFixture(TaskRecord.self, "plain/task-with-artifacts.json")
        snapshot.tasks.insert(task, at: 0)

        let encoded = try ProtocolJSON.encoder().encode(snapshot)
        let decoded = try ProtocolJSON.decoder().decode(Snapshot.self, from: encoded)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.tasks[0].artifacts, task.artifacts)
        XCTAssertNil(decoded.tasks[1].artifacts)

        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let tasks = json["tasks"] as! [[String: Any]]
        let original = try JSONSerialization.jsonObject(with: fixture("plain/task-with-artifacts.json")) as! NSDictionary
        XCTAssertEqual(tasks[0] as NSDictionary, original, "快照里的任务 JSON 应与单独的 fixture 逐键一致")
        XCTAssertFalse(tasks[1].keys.contains("artifacts"))

        let event = Event.snapshot(snapshot)
        XCTAssertEqual(try ProtocolJSON.decoder().decode(Event.self, from: ProtocolJSON.encoder().encode(event)), event)
    }

    // MARK: - 协议 2.6：不在项目中

    func testOutsideProjectTaskKeepsFlag() throws {
        let task = try decodeFixture(TaskRecord.self, "plain/task-outside-project.json")
        XCTAssertEqual(task.outsideProject, true)
        // 普通任务不带这个键：解码是 nil，再编码也不凭空写出 false 或 null。
        let plain = try decodeFixture(TaskRecord.self, "plain/task-waiting-input.json")
        XCTAssertNil(plain.outsideProject)
        let encoded = try JSONSerialization.jsonObject(with: ProtocolJSON.encoder().encode(plain)) as! [String: Any]
        XCTAssertNil(encoded["outsideProject"])
    }

    // MARK: - 协议 2.7：worktree

    func testWorktreeTaskKeepsBothPaths() throws {
        let task = try decodeFixture(TaskRecord.self, "plain/task-in-worktree.json")
        XCTAssertEqual(task.projectPath, "/Users/me/Projects/notes-app")
        XCTAssertEqual(task.workingDirectory, "/Users/me/Projects/notes-app/.claude/worktrees/settings-dark-mode-4f2a9c")
        // 不在 worktree 里的任务不带这个键，工作目录就是项目路径。
        let plain = try decodeFixture(TaskRecord.self, "plain/task-waiting-input.json")
        XCTAssertNil(plain.worktreePath)
        XCTAssertEqual(plain.workingDirectory, plain.projectPath)
        let encoded = try JSONSerialization.jsonObject(with: ProtocolJSON.encoder().encode(plain)) as! [String: Any]
        XCTAssertNil(encoded["worktreePath"])
    }

    func testStartTaskAllowsEmptyProjectPath() throws {
        let command = try decodeFixture(Command.self, "plain/command-start-task-outside-project.json")
        XCTAssertEqual(command.startTask?.projectPath, "")
        XCTAssertNil(command.startTask?.newProject)
    }

    func testStartTaskCarriesNewProjectAndAgentReportsRoot() throws {
        let command = try decodeFixture(Command.self, "plain/command-start-task-new-project.json")
        XCTAssertEqual(command.startTask?.newProject, "expense-tracker")
        let agent = try decodeFixture(AgentInfo.self, "plain/agent-info.json")
        XCTAssertEqual(agent.projectsRoot, "/Users/me/Documents/BotBusProjects")
    }

    func testNewProjectNameValidation() {
        for name in ["expense-tracker", "记账工具", "My App 2", "  padded  "] {
            XCTAssertTrue(Command.StartTask.isValidNewProjectName(name), name)
        }
        for name in ["", "   ", ".", "..", ".hidden", "a/b", "../escape", "a\\b", "a:b", "line\nbreak",
                     String(repeating: "x", count: Command.StartTask.maxNewProjectNameLength + 1)] {
            XCTAssertFalse(Command.StartTask.isValidNewProjectName(name), name)
        }
    }

    func testUnknownConnectorKindIsRejected() {
        XCTAssertThrowsError(try decodeFixture(AgentInfo.self, "plain/invalid/agent-info-bad-connector-kind.json"))
    }

    /// `connectors` 允许为空（刚被认领、还没连上的电脑），但最多 16 个且按 `(kind, connectorId)` 去重（协议 2.13）。
    /// 数量上限用 17 个互不相同的 connector 单独测，别让去重规则抢先抛错、把上限盖过去。
    func testConnectorListLimits() throws {
        // 刚被加进组、还没连上过的电脑：Relay 只有它的 id，没有密文。
        XCTAssertNil(try decodeFixture(PairAgentsResponse.self, "relay-pair-agents-response.json").agent.sealed)

        func agentJSON(_ connectors: [String]) -> Data {
            Data("""
            {"agentId":"hV3nQ7pLxK2mR8sTfW4bZQ","name":"Mac","platform":"macos","online":true,
             "lastSeenAt":"2026-09-17T08:00:00Z","appVersion":"0.3.0","connectors":[\(connectors.joined(separator: ","))]}
            """.utf8)
        }
        func builtin(_ kind: ConnectorKind) -> String {
            """
            {"kind":"\(kind.rawValue)","displayName":"\(kind.rawValue)","available":true,"enabled":true,\
            "status":"ok","taskCount":0}
            """
        }
        func acp(_ id: String) -> String {
            """
            {"kind":"acp","connectorId":"\(id)","displayName":"\(id)","available":true,"enabled":true,\
            "status":"ok","taskCount":0}
            """
        }

        XCTAssertNoThrow(try ProtocolJSON.decoder().decode(AgentInfo.self, from: agentJSON([builtin(.codex), builtin(.claude)])))
        // 只有 kind 与 connectorId 都相同才算重复：两个 ACP agent 的 id 不同就都留着。
        XCTAssertNoThrow(try ProtocolJSON.decoder().decode(AgentInfo.self, from: agentJSON([acp("gemini"), acp("my-agent")])))
        XCTAssertThrowsError(try ProtocolJSON.decoder().decode(AgentInfo.self, from: agentJSON([builtin(.codex), builtin(.codex)])),
                             "重复的 connector kind 必须被拒绝")
        XCTAssertThrowsError(try ProtocolJSON.decoder().decode(AgentInfo.self, from: agentJSON([acp("gemini"), acp("gemini")])),
                             "kind 与 connectorId 都相同的 ACP connector 必须被拒绝")

        // 一档 6 个 + ACP a01…a11，两两不同，只可能因为数量被拒（协议 3.1 起一档多了 dsh）。
        let builtins = ConnectorKind.allCases.filter { $0 != .acp }
        XCTAssertEqual(builtins.count, 6)
        let distinct = builtins.map(builtin)
            + (1...(AgentInfo.maxConnectors + 1 - builtins.count)).map { acp(String(format: "a%02d", $0)) }
        XCTAssertEqual(distinct.count, AgentInfo.maxConnectors + 1)
        XCTAssertNoThrow(try ProtocolJSON.decoder().decode(
            AgentInfo.self, from: agentJSON(Array(distinct.prefix(AgentInfo.maxConnectors)))),
                         "正好 \(AgentInfo.maxConnectors) 个互不相同的 connector 应当通过")
        XCTAssertThrowsError(try ProtocolJSON.decoder().decode(AgentInfo.self, from: agentJSON(distinct)),
                             "超过 \(AgentInfo.maxConnectors) 个 connector 必须被拒绝")
    }

    // MARK: - 语料对账与其他

    func testFixtureCorpusIsFullyCovered() throws {
        let manager = FileManager.default
        var onDisk = Set<String>()
        for entry in try manager.contentsOfDirectory(atPath: Self.fixturesDir.path) where entry.hasSuffix(".json") {
            onDisk.insert(entry)
        }
        for sub in ["invalid", "plain", "plain/invalid"] {
            let dir = Self.fixturesDir.appendingPathComponent(sub)
            for entry in try manager.contentsOfDirectory(atPath: dir.path) where entry.hasSuffix(".json") {
                onDisk.insert("\(sub)/\(entry)")
            }
        }

        let covered = Set((Self.snapshotCases + Self.taskCases + Self.artifactCases + Self.commandCases + Self.eventCases
            + Self.frameCases + Self.agentCases + Self.changesCases + Self.relayCases).map(\.name))
            .union(SealedFixtureTests.coveredNames)
            .union(SealedFixtureTests.coveredNames.map { "plain/\($0)" })
            .union(Self.invalidFixtureNames)

        let uncovered = onDisk.subtracting(covered).sorted()
        XCTAssertTrue(uncovered.isEmpty, "这些 fixture 没有被任何用例覆盖：\(uncovered)")
        let missing = covered.subtracting(onDisk).sorted()
        XCTAssertTrue(missing.isEmpty, "用例引用了不存在的 fixture：\(missing)")
    }

    func testCommandKindAccessor() throws {
        let command = try decodeFixture(Command.self, "plain/command-approve.json")
        XCTAssertEqual(command.kind, .approve)
        XCTAssertEqual(command.approve?.decision, .allow)
        XCTAssertNil(command.startTask)
        XCTAssertEqual(command.agentId, "hV3nQ7pLxK2mR8sTfW4bZQ")
    }

    func testTimestampFormat() throws {
        XCTAssertEqual(ProtocolJSON.timestamp(Date(timeIntervalSince1970: 1_789_583_264)), "2026-09-16T18:27:44Z")
        XCTAssertTrue(ProtocolJSON.timestamp().hasSuffix("Z"))
        XCTAssertNil(ProtocolJSON.timestamp().firstIndex(of: "."))
    }

    func testNotifyConstructors() throws {
        let approval = Notify.approval(taskId: "codex:x", requestId: "req-1", title: "t", body: "b")
        XCTAssertEqual(approval.category, .taskApproval)
        XCTAssertEqual(approval.requestId, "req-1")
        XCTAssertNil(Notify.done(taskId: "codex:x", title: "t", body: "b").requestId)
        XCTAssertEqual(Notify.Category.allCases.count, 4)
    }
}
