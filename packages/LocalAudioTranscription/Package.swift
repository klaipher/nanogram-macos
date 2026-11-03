// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "LocalAudioTranscription",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "LocalAudioTranscription", targets: ["LocalAudioTranscription"]),
    ],
    dependencies: [
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "OpusBinding", path: "../../submodules/telegram-ios/submodules/OpusBinding"),
        .package(name: "VoiceRecorderInput", path: "../VoiceRecorderInput"),
        .package(name: "NanogramDebug", path: "../NanogramDebug"),
    ],
    targets: [
        .target(
            name: "LocalAudioTranscription",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "OpusBinding", package: "OpusBinding", condition: nil),
                .product(name: "NanogramDebug", package: "NanogramDebug", condition: nil),
            ],
            path: "Sources/LocalAudioTranscription"),
        .testTarget(
            name: "LocalAudioTranscriptionTests",
            dependencies: [
                "LocalAudioTranscription",
                .product(name: "VoiceRecorderInput", package: "VoiceRecorderInput"),
                .product(name: "NanogramDebug", package: "NanogramDebug"),
            ],
            path: "Tests/LocalAudioTranscriptionTests"),
    ]
)
