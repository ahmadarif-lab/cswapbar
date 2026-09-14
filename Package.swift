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
        .executableTarget(
            name: "CSwapBar",
            dependencies: ["SwapEngine"],
            path: "Sources/CSwapBar"
        ),
        .testTarget(
            name: "SwapEngineTests",
            dependencies: ["SwapEngine"],
            path: "Tests/SwapEngineTests"
        ),
    ]
)
