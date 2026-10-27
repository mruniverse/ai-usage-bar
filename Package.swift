// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "AIUsageBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AIUsageBar", targets: ["AIUsageBar"])],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "AIUsageBar", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ]
)
