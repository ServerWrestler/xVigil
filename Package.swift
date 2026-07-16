// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xVigil",
    platforms: [.macOS(.v15)],
    targets: [
        // Core: quarantine database access, XProtect log parsing, system status.
        // Pure-read by design — active scanning lives in xVigilScan.
        .target(name: "xVigilCore"),
        // On-demand scanning: ScanEngine protocol + detected engine backends.
        .target(name: "xVigilScan", dependencies: ["xVigilCore"]),
        // Menu bar app.
        .executableTarget(
            name: "xVigil",
            dependencies: ["xVigilCore", "xVigilScan"]
        ),
        // CLI harness for prototyping the data layer without the UI.
        .executableTarget(
            name: "xvigil-cli",
            dependencies: ["xVigilCore", "xVigilScan"]
        ),
        .testTarget(
            name: "xVigilCoreTests",
            dependencies: ["xVigilCore"]
        ),
        .testTarget(
            name: "xVigilScanTests",
            dependencies: ["xVigilScan"]
        ),
    ]
)
