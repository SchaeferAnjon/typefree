// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoicePolishCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "VoicePolishCore",
            targets: ["VoicePolishCore"]
        ),
    ],
    targets: [
        .target(
            name: "VoicePolishCore",
            path: "Sources/VoicePolishCore",
            linkerSettings: [
                .linkedFramework("IOKit", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "VoicePolishCoreTests",
            dependencies: ["VoicePolishCore"],
            path: "Tests/VoicePolishCoreTests"
        )
    ]
)
