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
        .target(
            name: "DeepSeekEngine",
            dependencies: ["ProviderKit"],
            path: "Sources/DeepSeekEngine"
        ),
        .target(
            name: "OpenCodeGoEngine",
            dependencies: ["ProviderKit"],
            path: "Sources/OpenCodeGoEngine"
        ),
        .target(
            name: "KiroEngine",
            dependencies: ["ProviderKit"],
            path: "Sources/KiroEngine"
        ),
        .target(
            name: "CodexEngine",
            dependencies: ["ProviderKit"],
            path: "Sources/CodexEngine"
        ),
        .executableTarget(
            name: "CSwapBar",
            dependencies: ["SwapEngine", "AntigravityEngine", "ZAIEngine", "DeepSeekEngine", "OpenCodeGoEngine", "KiroEngine", "CodexEngine", "ProviderKit"],
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
            name: "DeepSeekEngineTests",
            dependencies: ["DeepSeekEngine"],
            path: "Tests/DeepSeekEngineTests"
        ),
        .testTarget(
            name: "OpenCodeGoEngineTests",
            dependencies: ["OpenCodeGoEngine"],
            path: "Tests/OpenCodeGoEngineTests"
        ),
        .testTarget(
            name: "KiroEngineTests",
            dependencies: ["KiroEngine"],
            path: "Tests/KiroEngineTests"
        ),
        .testTarget(
            name: "CodexEngineTests",
            dependencies: ["CodexEngine"],
            path: "Tests/CodexEngineTests"
        ),
        .testTarget(
            name: "AntigravityEngineTests",
            dependencies: ["AntigravityEngine"],
            path: "Tests/AntigravityEngineTests"
        ),
    ]
)
