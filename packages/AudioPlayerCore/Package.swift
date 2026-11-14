// swift-tools-version:5.9

import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
]

let deps: [(String, String)] = [
    ("TGUIKit", "../TGUIKit"),
    ("Localization", "../Localization"),
    ("TelegramTheme", "../TelegramTheme"),
    ("TelegramContext", "../TelegramContext"),
    ("TelegramUtils", "../TelegramUtils"),
    ("TelegramMediaUtils", "../TelegramMediaUtils"),
    ("TelegramMedia", "../TelegramMedia"),
    ("ChatModeTypes", "../ChatModeTypes"),
    ("MessageUtils", "../MessageUtils"),
    ("RangeSet", "../../submodules/telegram-ios/submodules/Utils/RangeSet"),
    ("TelegramMediaResources", "../TelegramMediaResources"),
]

let package = Package(
    name: "AudioPlayerCore",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "AudioPlayerCore", targets: ["AudioPlayerCore"]),
    ],
    dependencies: [
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "TelegramCore", path: "../../submodules/telegram-ios/submodules/TelegramCore"),
        .package(name: "Postbox", path: "../../submodules/telegram-ios/submodules/Postbox"),
        .package(name: "TelegramMediaPlayer", path: "../../submodules/telegram-ios/submodules/MediaPlayer"),
        .package(name: "rnoise", path: "../../submodules/telegram-ios/third-party/rnnoise"),
    ] + deps.map { .package(name: $0.0, path: $0.1) },
    targets: [
        .target(
            name: "AudioPlayerCore",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "TelegramCore", package: "TelegramCore", condition: nil),
                .product(name: "Postbox", package: "Postbox", condition: nil),
            ] + deps.map { .product(name: $0.0, package: $0.0, condition: nil) },
            path: "Sources/AudioPlayerCore",
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "AudioPlayerCoreTests",
            dependencies: [
                "AudioPlayerCore",
                .product(name: "TelegramMedia", package: "TelegramMedia"),
                .product(name: "SwiftSignalKit", package: "SSignalKit"),
                .product(name: "Postbox", package: "Postbox"),
                .product(name: "TelegramMediaPlayer", package: "TelegramMediaPlayer"),
                .product(name: "rnoise", package: "rnoise"),
            ],
            path: "Tests/AudioPlayerCoreTests"),
    ]
)
