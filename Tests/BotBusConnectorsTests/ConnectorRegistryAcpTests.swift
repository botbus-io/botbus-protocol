import Foundation
import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class ConnectorRegistryAcpTests: XCTestCase {
    private func entry(_ id: String, name: String? = nil, defaultEnabled: Bool = true,
                       canStartTask: Bool = true) -> ConnectorRegistry.AcpEntry {
        ConnectorRegistry.AcpEntry(id: id, displayName: name ?? id, defaultEnabled: defaultEnabled,
                                   canStartTask: canStartTask, status: .ok, lastError: nil)
    }

    private func registry(acpEnabled: [String: Bool] = [:]) -> ConnectorRegistry {
        ConnectorRegistry(descriptors: ConnectorDescriptor.all(codexBinary: { nil }, claudeBinary: { nil },
                                                               hermesBinary: { nil }, piBinary: { nil },
                                                               openClawBinary: { nil },
                                                               dshPaths: { DshPaths(home: URL(fileURLWithPath: "/nonexistent-dsh")) },
                                                               dshInstallation: { nil }),
                          acpEnabled: acpEnabled)
    }

    func testBuiltinDescriptorsSkipAcp() {
        XCTAssertFalse(registry().kinds.contains(.acp))
        XCTAssertTrue(registry().isEnabled(.acp), "acp 这一层恒为开，逐个 agent 的开关在 isAcpEnabled")
    }

    func testEntriesAndDefaults() {
        let registry = registry()
        XCTAssertTrue(registry.setAcpEntries([entry("gemini"), entry("quiet", defaultEnabled: false)]))
        XCTAssertFalse(registry.setAcpEntries([entry("gemini"), entry("quiet", defaultEnabled: false)]), "没变化不算改")
        XCTAssertTrue(registry.isAcpEnabled("gemini"))
        XCTAssertFalse(registry.isAcpEnabled("quiet"))
        XCTAssertFalse(registry.isAcpEnabled("unknown"), "没发现到的一律当关")
        XCTAssertTrue(registry.isAvailable(.acp))
    }

    func testTogglesAreRememberedEvenWhenAgentDisappears() {
        let registry = registry()
        registry.setAcpEntries([entry("gemini")])
        XCTAssertTrue(registry.setAcpEnabled(false, for: "gemini"))
        XCTAssertFalse(registry.setAcpEnabled(false, for: "gemini"))
        registry.setAcpEntries([])
        XCTAssertEqual(registry.acpEnabledOverrides, ["gemini": false])
        registry.setAcpEntries([entry("gemini")])
        XCTAssertFalse(registry.isAcpEnabled("gemini"), "卸了重装还记得用户关过")
    }

    func testOverridesFromSettings() {
        let registry = registry(acpEnabled: ["quiet": true])
        registry.setAcpEntries([entry("quiet", defaultEnabled: false)])
        XCTAssertTrue(registry.isAcpEnabled("quiet"))
    }

    func testConnectorInfosIncludeAcpWithCounts() {
        let registry = registry()
        registry.setAcpEntries([entry("gemini", name: "Gemini CLI"), entry("daemon", canStartTask: false)])
        let infos = registry.connectors(taskCounts: [.acp("gemini"): 2])
        let acp = infos.filter { $0.kind == .acp }
        XCTAssertEqual(acp.map(\.connectorId), ["daemon", "gemini"], "按显示名排")
        XCTAssertEqual(acp.first { $0.connectorId == "gemini" }?.taskCount, 2)
        XCTAssertNil(acp.first { $0.connectorId == "gemini" }?.canStartTask)
        XCTAssertEqual(acp.first { $0.connectorId == "daemon" }?.canStartTask, false)
    }

    func testCapacityKeepsTotalWithinProtocolLimit() {
        let registry = registry()
        registry.setAcpEntries((0..<30).map { entry(String(format: "agent-%02d", $0)) })
        let infos = registry.connectors()
        XCTAssertLessThanOrEqual(infos.count, AgentInfo.maxConnectors)
        XCTAssertEqual(registry.acpIds.count, registry.acpCapacity)
    }

    func testAcpDisplayName() {
        let registry = registry()
        registry.setAcpEntries([entry("gemini")])
        XCTAssertEqual(registry.acpDisplayName("gemini"), registry.connectors().first { $0.connectorId == "gemini" }?.displayName)
        XCTAssertNil(registry.acpDisplayName("nope"))
    }
}
