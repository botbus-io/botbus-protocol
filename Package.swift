// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "botbus-protocol",
    // Package-level platforms are the minimum deployment targets. BotBusConnectorKit and BotBusConnectors only
    // build on macOS (they drive local agent processes); iOS and watchOS consumers link BotBusProtocol alone,
    // and SwiftPM / Xcode only compile the targets a product actually depends on.
    platforms: [.macOS("26.0"), .iOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "BotBusProtocol", targets: ["BotBusProtocol"]),
        .library(name: "BotBusConnectorKit", targets: ["BotBusConnectorKit"]),
        .library(name: "BotBusConnectors", targets: ["BotBusConnectors"]),
    ],
    targets: [
        .target(name: "BotBusProtocol"),
        .target(
            name: "BotBusConnectorKit",
            dependencies: ["BotBusProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BotBusConnectors",
            dependencies: ["BotBusProtocol", "BotBusConnectorKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "BotBusProtocolTests", dependencies: ["BotBusProtocol"]),
        .testTarget(
            name: "BotBusConnectorKitTests",
            dependencies: ["BotBusConnectorKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BotBusConnectorsTests",
            dependencies: ["BotBusConnectors"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
