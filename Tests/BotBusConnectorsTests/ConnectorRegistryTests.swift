import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

final class ConnectorRegistryTests: XCTestCase {
    /// 假探测：不碰文件系统，直接给出每个 kind 的结果。
    private func descriptor(_ kind: ConnectorKind, available: Bool, status: ConnectorInfo.Status = .ok,
                            lastError: String? = nil, defaultEnabled: Bool = true) -> ConnectorDescriptor {
        ConnectorDescriptor(kind: kind, displayName: kind.rawValue.capitalized, defaultEnabled: defaultEnabled) {
            ConnectorProbe(available: available, status: status, lastError: lastError)
        }
    }

    func testReportsCodexAvailableAndClaudeUnavailable() {
        let registry = ConnectorRegistry(descriptors: [
            descriptor(.codex, available: true),
            descriptor(.claude, available: false, status: .degraded, lastError: "尚未接入", defaultEnabled: false),
        ])
        let infos = registry.connectors()
        XCTAssertEqual(infos.map(\.kind), [.codex, .claude])
        XCTAssertTrue(infos[0].available)
        XCTAssertTrue(infos[0].enabled)
        XCTAssertEqual(infos[0].status, .ok)
        XCTAssertFalse(infos[1].available)
        XCTAssertFalse(infos[1].enabled, "探测不到的 Connector 默认不启用")
        XCTAssertEqual(infos[1].status, .degraded)
        XCTAssertEqual(infos[1].lastError, "尚未接入")
        XCTAssertEqual(infos.map(\.taskCount), [0, 0])
    }

    /// 协议 3.3：只有 Codex 与 Claude 报 `canAutoApprove`（只写 true），本机没装时也不报。
    func testOnlyCodexAndClaudeReportAutoApprove() {
        let registry = ConnectorRegistry(descriptors: [
            descriptor(.codex, available: true),
            descriptor(.claude, available: false),
            descriptor(.hermes, available: true),
            descriptor(.dsh, available: true),
        ])
        let infos = registry.connectors()
        XCTAssertEqual(infos.map(\.canAutoApprove), [true, nil, nil, nil])
        XCTAssertEqual(ConnectorKind.allCases.filter(\.supportsAutoApprove), [.codex, .claude])
    }

    func testTaskCountsComeFromTheCaller() {
        let registry = ConnectorRegistry(descriptors: [descriptor(.codex, available: true), descriptor(.claude, available: false)])
        let infos = registry.connectors(taskCounts: [ConnectorRef(kind: .codex): 7])
        XCTAssertEqual(infos.first { $0.kind == .codex }?.taskCount, 7)
        XCTAssertEqual(infos.first { $0.kind == .claude }?.taskCount, 0, "没报数的一律 0，不是 nil")
    }

    func testSetEnabledOnlyReportsRealChanges() {
        let registry = ConnectorRegistry(descriptors: [descriptor(.codex, available: true)])
        XCTAssertTrue(registry.isEnabled(.codex))
        XCTAssertTrue(registry.setEnabled(false, for: .codex))
        XCTAssertFalse(registry.setEnabled(false, for: .codex), "值没变就不该报告变化")
        XCTAssertFalse(registry.isEnabled(.codex))
        XCTAssertFalse(registry.connectors()[0].enabled)
        XCTAssertEqual(registry.enabledKinds, [])
        XCTAssertTrue(registry.setEnabled(true, for: .codex))
        XCTAssertEqual(registry.enabledKinds, [.codex])
    }

    /// 2.5 的三个来源没装就不上报；装上之后（refresh）才出现。Codex / Claude 不装也照报。
    func testNewSourcesAreHiddenUntilDetected() {
        let installed = NSLock()
        nonisolated(unsafe) var isInstalled = false
        let registry = ConnectorRegistry(descriptors: [
            descriptor(.codex, available: false, status: .degraded),
            ConnectorDescriptor(kind: .pi, displayName: "Pi", defaultEnabled: true, reportsWhenUnavailable: false) {
                let value = installed.withLock { isInstalled }
                return ConnectorProbe(available: value, status: value ? .ok : .degraded)
            },
        ])
        XCTAssertEqual(registry.connectors().map(\.kind), [.codex])
        installed.withLock { isInstalled = true }
        registry.refresh()
        XCTAssertEqual(registry.connectors().map(\.kind), [.codex, .pi])
    }

    func testRealDescriptorsHideMissingNewSourcesAndDefaultOpenClawOff() {
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let registry = ConnectorRegistry(descriptors: ConnectorDescriptor.all(
            codexPaths: { CodexPaths(codexHome: nowhere) }, codexBinary: { nil },
            claudePaths: { ClaudePaths(claudeHome: nowhere) }, claudeBinary: { nil },
            hermesPaths: { HermesPaths(hermesHome: nowhere) }, hermesBinary: { nil },
            piPaths: { PiPaths(agentDirectory: nowhere) }, piBinary: { nil },
            openClawPaths: { OpenClawPaths(stateDirectory: nowhere) }, openClawBinary: { "/usr/bin/true" },
            dshPaths: { DshPaths(home: nowhere) }, dshInstallation: { nil }))
        XCTAssertEqual(registry.connectors().map(\.kind), [.codex, .claude, .openclaw])
        XCTAssertTrue(registry.isEnabled(.hermes))
        XCTAssertTrue(registry.isEnabled(.pi))
        XCTAssertFalse(registry.isEnabled(.openclaw), "OpenClaw 是个人助理，会话要用户同意才同步")
        let openClaw = registry.connectors().first { $0.kind == .openclaw }
        XCTAssertEqual(openClaw?.status, .degraded, "只有可执行文件、没有配置")
    }

    /// 运行期问题（Gateway 连不上）覆盖探测状态；不可用的 kind 不动；refresh 回到探测结果。
    func testRuntimeReportOverridesProbeUntilRefresh() {
        let registry = ConnectorRegistry(descriptors: [
            descriptor(.openclaw, available: true),
            descriptor(.pi, available: false, status: .degraded),
        ])
        XCTAssertTrue(registry.reportRuntime(status: .degraded, lastError: "连不上", for: .openclaw))
        XCTAssertFalse(registry.reportRuntime(status: .degraded, lastError: "连不上", for: .openclaw), "没变不算")
        XCTAssertFalse(registry.reportRuntime(status: .error, lastError: "x", for: .pi))
        let info = registry.connectors().first { $0.kind == .openclaw }
        XCTAssertEqual(info?.status, .degraded)
        XCTAssertEqual(info?.lastError, "连不上")
        registry.refresh()
        XCTAssertEqual(registry.connectors().first { $0.kind == .openclaw }?.status, .ok)
    }

    /// 没有描述符的 kind 不能凭空冒出来，也不能让调用方拿到一个假的 ConnectorInfo。
    func testUnknownKindIsIgnored() {
        let registry = ConnectorRegistry(descriptors: [descriptor(.codex, available: true)])
        XCTAssertEqual(registry.kinds, [.codex])
        XCTAssertFalse(registry.setEnabled(true, for: .claude))
        XCTAssertFalse(registry.isEnabled(.claude))
        XCTAssertEqual(registry.connectors().map(\.kind), [.codex])
    }

    func testInitialEnabledOverridesDefaults() {
        let registry = ConnectorRegistry(
            descriptors: [descriptor(.codex, available: true), descriptor(.claude, available: false, defaultEnabled: false)],
            enabled: [.codex: false, .claude: true])
        XCTAssertFalse(registry.isEnabled(.codex))
        XCTAssertTrue(registry.isEnabled(.claude))
    }

    func testDisplayNameAndLastErrorAreTruncated() {
        let registry = ConnectorRegistry(descriptors: [
            ConnectorDescriptor(kind: .codex, displayName: String(repeating: "名", count: 80), defaultEnabled: true) {
                ConnectorProbe(available: false, status: .error, lastError: String(repeating: "错", count: 300))
            },
        ])
        let info = registry.connectors()[0]
        XCTAssertEqual(info.displayName.count, ConnectorRegistry.displayNameLimit)
        XCTAssertEqual(info.lastError?.count, ConnectorRegistry.lastErrorLimit)
    }

    // MARK: - 默认描述符（真实探测，但只指向临时目录）

    func testDefaultCodexDescriptorReadsBinaryAndDatabasePresence() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("botbus-conn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // 两个库都没有、也没有可执行文件：不可用。
        let missing = ConnectorRegistry(descriptors: ConnectorDescriptor.all(codexPaths: { CodexPaths(codexHome: home) },
                                                                            codexBinary: { nil }))
        let missingCodex = try XCTUnwrap(missing.connectors().first { $0.kind == .codex })
        XCTAssertFalse(missingCodex.available)
        XCTAssertEqual(missingCodex.status, .degraded)

        // 只有可执行文件：可用但降级。
        let binaryOnly = ConnectorRegistry(descriptors: ConnectorDescriptor.all(codexPaths: { CodexPaths(codexHome: home) },
                                                                               codexBinary: { "/usr/bin/true" }))
        let binaryCodex = try XCTUnwrap(binaryOnly.connectors().first { $0.kind == .codex })
        XCTAssertTrue(binaryCodex.available)
        XCTAssertEqual(binaryCodex.status, .degraded)

        // 两个库齐全 + 可执行文件：ok。
        for name in ["state_3.sqlite", "thread_history_1.sqlite"] {
            try Data().write(to: home.appendingPathComponent(name))
        }
        let full = ConnectorRegistry(descriptors: ConnectorDescriptor.all(codexPaths: { CodexPaths(codexHome: home) },
                                                                         codexBinary: { "/usr/bin/true" }))
        let fullCodex = try XCTUnwrap(full.connectors().first { $0.kind == .codex })
        XCTAssertTrue(fullCodex.available)
        XCTAssertEqual(fullCodex.status, .ok)
        XCTAssertNil(fullCodex.lastError)
    }

    /// 默认描述符覆盖每一个**编译期**的 ConnectorKind：新增 kind 时这里会立刻变红，提醒去加一个 case。
    /// `.acp` 是例外——ACP agent 由运行时发现，不在这张编译期的表里（由 `AcpHub` 经 `setAcpEntries` 写入）。
    func testDefaultDescriptorsCoverEveryConnectorKind() {
        let builtIn = ConnectorKind.allCases.filter { $0 != .acp }
        let kinds = ConnectorDescriptor.all(codexPaths: { CodexPaths(codexHome: URL(fileURLWithPath: "/nonexistent")) },
                                            codexBinary: { nil }).map(\.kind)
        XCTAssertEqual(kinds, builtIn)
        let registry = ConnectorRegistry(descriptors: nothingInstalled())
        // 什么都没装时只有 Codex / Claude 占位；2.5 的三个来源装上才出现。
        XCTAssertEqual(registry.connectors().map(\.kind), [.codex, .claude])
        XCTAssertEqual(registry.kinds, builtIn)
    }

    /// Claude 的探测分四档，前两档是用户最常撞见的：装了但没装 hooks、以及压根没装。
    func testClaudeProbeReflectsBinaryAndHooks() {
        let missing = ConnectorRegistry(descriptors: nothingInstalled()).connectors()
        let claude = try! XCTUnwrap(missing.first { $0.kind == .claude })
        XCTAssertFalse(claude.available)
        XCTAssertEqual(claude.lastError, "本机未检测到 Claude Code")

        let home = URL(fileURLWithPath: NSTemporaryDirectory())
        let noHooks = ConnectorRegistry(descriptors: [ConnectorDescriptor.claude(
            paths: { ClaudePaths(claudeHome: home) }, binary: { "/usr/local/bin/claude" }, hooksInstalled: { false })])
        let degraded = try! XCTUnwrap(noHooks.connectors().first)
        XCTAssertTrue(degraded.available, "装了 claude 就算检测到")
        XCTAssertEqual(degraded.status, .degraded)
        XCTAssertEqual(degraded.lastError?.contains("还没安装 hooks"), true)

        let ready = ConnectorRegistry(descriptors: [ConnectorDescriptor.claude(
            paths: { ClaudePaths(claudeHome: home) }, binary: { "/usr/local/bin/claude" }, hooksInstalled: { true })])
        let ok = try! XCTUnwrap(ready.connectors().first)
        XCTAssertTrue(ok.available)
        XCTAssertEqual(ok.status, .ok)
        XCTAssertNil(ok.lastError)
    }

    /// DeepSeek Harness：什么都没有不上报；只有 `sessions/` 能看不能新建（`canStartTask: false`）；有可执行文件才是 ok。
    func testDshProbe() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = DshInstallation(kind: .binary, executable: "/usr/local/bin/dsh", leadingArguments: [], version: nil, node: nil)
        let none = ConnectorRegistry(descriptors: [ConnectorDescriptor.dsh(paths: { DshPaths(home: home) }, installation: { nil })])
        XCTAssertTrue(none.connectors().isEmpty)
        XCTAssertTrue(none.isEnabled(.dsh), "默认开")

        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        none.refresh()
        let readOnly = try XCTUnwrap(none.connectors().first)
        XCTAssertEqual(readOnly.kind, .dsh)
        XCTAssertEqual(readOnly.displayName, "DeepSeek Harness")
        XCTAssertTrue(readOnly.available)
        XCTAssertEqual(readOnly.status, .degraded)
        XCTAssertEqual(readOnly.canStartTask, false)

        let full = ConnectorRegistry(descriptors: [ConnectorDescriptor.dsh(paths: { DshPaths(home: home) }, installation: { binary })])
        let ok = try XCTUnwrap(full.connectors().first)
        XCTAssertEqual(ok.status, .ok)
        XCTAssertNil(ok.canStartTask, "能新建时省略")
        XCTAssertNil(ok.lastError)
    }

    /// 什么都没装的一台机器。
    private func nothingInstalled() -> [ConnectorDescriptor] {
        ConnectorDescriptor.all(codexPaths: { CodexPaths(codexHome: URL(fileURLWithPath: "/nonexistent")) },
                                codexBinary: { nil },
                                claudePaths: { ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")) },
                                claudeBinary: { nil },
                                claudeHooksInstalled: { false },
                                hermesPaths: { HermesPaths(hermesHome: URL(fileURLWithPath: "/nonexistent")) },
                                hermesBinary: { nil },
                                piPaths: { PiPaths(agentDirectory: URL(fileURLWithPath: "/nonexistent")) },
                                piBinary: { nil },
                                openClawPaths: { OpenClawPaths(stateDirectory: URL(fileURLWithPath: "/nonexistent")) },
                                openClawBinary: { nil },
                                dshPaths: { DshPaths(home: URL(fileURLWithPath: "/nonexistent")) },
                                dshInstallation: { nil })
    }
}
