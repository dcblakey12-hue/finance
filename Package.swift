// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Finance",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Finance", targets: ["Finance"])
    ],
    targets: [
        .executableTarget(
            name: "Finance",
            path: "Sources/Finance",
            exclude: ["Info.plist", "Finance.entitlements"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "FinanceTests",
            dependencies: ["Finance"],
            path: "Tests/FinanceTests",
            resources: [.process("Resources")]
        ),
    ]
)
