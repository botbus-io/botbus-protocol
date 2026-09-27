// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BotBusConnectorParsers",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "BotBusConnectorParsers", targets: ["BotBusConnectorParsers"]),
    ],
    targets: [
        .target(name: "BotBusConnectorParsers", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BotBusConnectorParsersTests", dependencies: ["BotBusConnectorParsers"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
