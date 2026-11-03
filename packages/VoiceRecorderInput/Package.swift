// swift-tools-version:6.2

import PackageDescription

let nanogramSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

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
            path: "Sources/VoiceRecorderInput",
            swiftSettings: nanogramSwiftSettings),
        .testTarget(
            name: "VoiceRecorderInputTests",
            dependencies: [
                "VoiceRecorderInput",
                .product(name: "OpusBinding", package: "OpusBinding"),
            ],
            path: "Tests/VoiceRecorderInputTests",
            swiftSettings: nanogramSwiftSettings,
            linkerSettings: [.unsafeFlags(["-L", "../../core-xprojects/libopus/build/libopus/lib", "-lopus"])]),
    ],
    swiftLanguageModes: [.v6]
)
