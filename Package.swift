// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CSwapBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SwapEngine",
            path: "Sources/SwapEngine"
        ),
        .target(
            name: "ProviderKit",
            path: "Sources/ProviderKit"
        ),
        .target(
            name: "AntigravityEngine",
            dependencies: ["ProviderKit"],
            path: "Sources/AntigravityEngine"
        ),
        .target(
            name: "ZAIEngine",
            dependencies: ["ProviderKit"],
            path: "Sources/ZAIEngine"
        ),
        .executableTarget(
            name: "CSwapBar",
            dependencies: ["SwapEngine", "AntigravityEngine", "ZAIEngine"],
            path: "Sources/CSwapBar"
        ),
        .testTarget(
            name: "SwapEngineTests",
            dependencies: ["SwapEngine"],
            path: "Tests/SwapEngineTests"
        ),
        .testTarget(
            name: "ZAIEngineTests",
            dependencies: ["ZAIEngine"],
            path: "Tests/ZAIEngineTests"
        ),
        .testTarget(
            name: "AntigravityEngineTests",
            dependencies: ["AntigravityEngine"],
            path: "Tests/AntigravityEngineTests"
        ),
    ]
)
