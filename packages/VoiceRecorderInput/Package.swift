// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "VoiceRecorderInput",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "VoiceRecorderInput", targets: ["VoiceRecorderInput"]),
    ],
    dependencies: [
        .package(name: "OpusBinding", path: "../../submodules/telegram-ios/submodules/OpusBinding"),
    ],
    targets: [
        .target(
            name: "VoiceRecorderInput",
            dependencies: [],
            path: "Sources/VoiceRecorderInput"),
        .testTarget(
            name: "VoiceRecorderInputTests",
            dependencies: [
                "VoiceRecorderInput",
                .product(name: "OpusBinding", package: "OpusBinding"),
            ],
            path: "Tests/VoiceRecorderInputTests"),
    ]
)
