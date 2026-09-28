import XCTest
@testable import BotBusProtocol

/// 跨端枚举冻结（`docs/compatibility.md`）：这些枚举的每个值都是装在用户手机上的 app 必须认得的。
/// 改动任何一个清单都必须同时升 `ProtocolVersion.current`、改 `PROTOCOL.md` 与 `docs/compatibility.md`，
/// 并在 PR 里写清是否需要发手机版；新 agent 一律走 `acp` + `connectorId`，不加来源值。
final class ProtocolFreezeTests: XCTestCase {
    private func assertFrozen<E: CaseIterable & RawRepresentable>(_ type: E.Type, _ expected: [String],
                                                                  file: StaticString = #filePath, line: UInt = #line)
    where E.RawValue == String {
        XCTAssertEqual(E.allCases.map(\.rawValue), expected,
                       "\(E.self) changed — bump ProtocolVersion.current and update PROTOCOL.md / docs/compatibility.md",
                       file: file, line: line)
    }

    func testTaskSourceIsFrozen() {
        assertFrozen(TaskSource.self, ["codex", "claude", "hermes", "pi", "openclaw", "acp", "dsh"])
    }

    func testConnectorKindIsFrozen() {
        assertFrozen(ConnectorKind.self, ["codex", "claude", "hermes", "pi", "openclaw", "acp", "dsh"])
    }

    func testTaskStatusIsFrozen() {
        assertFrozen(TaskStatus.self, ["running", "waitingApproval", "waitingInput", "completed", "failed", "interrupted", "idle"])
    }

    func testTaskOriginIsFrozen() {
        assertFrozen(TaskOrigin.self, ["watch", "desktop"])
    }

    func testPendingRequestKindIsFrozen() {
        assertFrozen(PendingRequest.Kind.self, ["command", "fileChange", "permission", "input"])
    }

    func testArtifactKindIsFrozen() {
        assertFrozen(ArtifactKind.self, ["image", "file", "video", "preview", "link"])
    }

    func testCommandKindIsFrozen() {
        assertFrozen(Command.Kind.self, ["startTask", "followUp", "approve", "interrupt", "setConnectorEnabled",
                                         "fetchMessages", "fetchFile", "fetchChanges", "remoteControl", "mergeWorktree"])
    }

    func testEventKindIsFrozen() {
        assertFrozen(Event.Kind.self, ["snapshot", "taskUpdated", "taskRemoved", "commandResult", "notify", "taskMessages"])
    }

    func testNotifyCategoryIsFrozen() {
        assertFrozen(Notify.Category.self, ["TASK_APPROVAL", "TASK_INPUT", "TASK_DONE", "TASK_FAILED"])
    }

    func testMessageRoleIsFrozen() {
        assertFrozen(Message.Role.self, ["user", "agent", "tool"])
    }

    func testConnectorStatusIsFrozen() {
        assertFrozen(ConnectorInfo.Status.self, ["ok", "degraded", "error"])
    }

    func testProtocolVersionMatchesTheFrozenContract() {
        XCTAssertEqual(ProtocolVersion.current, "3.4")
    }
}
