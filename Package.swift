// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xVigil",
    platforms: [.macOS(.v14)],
    targets: [
        // Core: quarantine database access, XProtect log parsing, system status.
        .target(name: "xVigilCore"),
        // Menu bar app.
        .executableTarget(
            name: "xVigil",
            dependencies: ["xVigilCore"]
        ),
        // CLI harness for prototyping the data layer without the UI.
        .executableTarget(
            name: "xvigil-cli",
            dependencies: ["xVigilCore"]
        ),
        .testTarget(
            name: "xVigilCoreTests",
            dependencies: ["xVigilCore"]
        ),
    ]
)
