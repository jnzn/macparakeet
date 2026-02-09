// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacParakeet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacParakeet", targets: ["MacParakeet"]),
        .library(name: "MacParakeetCore", targets: ["MacParakeetCore"])
    ],
    dependencies: [
        // MLX-Swift for local LLM inference (Qwen3-4B)
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.29.0"),
        // GRDB for SQLite (dictation history + transcription records)
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        // Main GUI app
        .executableTarget(
            name: "MacParakeet",
            dependencies: ["MacParakeetCore"],
            path: "Sources/MacParakeet"
        ),
        // Shared core library (no UI dependencies)
        .target(
            name: "MacParakeetCore",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MacParakeetCore"
        ),
        // Tests
        .testTarget(
            name: "MacParakeetTests",
            dependencies: ["MacParakeetCore"],
            path: "Tests/MacParakeetTests"
        )
    ]
)
