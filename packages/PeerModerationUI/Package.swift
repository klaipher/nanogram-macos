// swift-tools-version:5.5

import PackageDescription
import Foundation

let coreLibraries: [(path: String, name: String)] = [
    ("webrtc/build/webrtc", "mac_framework_objc_static"),
    ("boringssl/build/boringssl/lib", "ssl"),
    ("boringssl/build/boringssl/lib", "crypto"),
    ("ffmpeg/build/ffmpeg/lib", "avformat"),
    ("ffmpeg/build/ffmpeg/lib", "avcodec"),
    ("ffmpeg/build/ffmpeg/lib", "swresample"),
    ("ffmpeg/build/ffmpeg/lib", "avutil"),
    ("OpenH264/build/output/lib", "openh264"),
    ("libvpx/build/libvpx/lib", "vpx"),
    ("dav1d/build/dav1d/lib", "dav1d"),
    ("libopus/build/libopus/lib", "opus"),
    ("Mozjpeg/build", "jpeg"),
    ("libwebp/build/libwebp/lib", "webpdemux"),
    ("libwebp/build/libwebp/lib", "webpdecoder"),
    ("libwebp/build/libwebp/lib", "webp"),
    ("libwebp/build/libwebp/lib", "sharpyuv"),
    ("tde2e/build/tde2e/lib", "tde2e"),
    ("tde2e/build/tde2e/lib", "tdutils"),
]
let coreXprojects = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../core-xprojects").standardized
let coreLinkerFlags: [String] = coreLibraries.flatMap { ["-L", coreXprojects.appendingPathComponent($0.path).path, "-l\($0.name)"] }

let deps: [(String, String)] = [
    ("TGUIKit", "../TGUIKit"),
    ("InAppSettings", "../InAppSettings"),
    ("Localization", "../Localization"),
    ("Strings", "../Strings"),
    ("TelegramTheme", "../TelegramTheme"),
    ("TelegramContext", "../TelegramContext"),
    ("TelegramUtils", "../TelegramUtils"),
    ("LocalAnimations", "../LocalAnimations"),
    ("ChatHistoryModel", "../ChatHistoryModel"),
    ("ChatUI", "../ChatUI"),
    ("ShortPeerRow", "../ShortPeerRow"),
    ("GeneralRows", "../GeneralRows"),
    ("InputDataUI", "../InputDataUI"),
    ("AlertsUI", "../AlertsUI"),
    ("SelectPeersUI", "../SelectPeersUI"),
    ("AppAnalytics", "../AppAnalytics"),
]

let package = Package(
    name: "PeerModerationUI",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "PeerModerationUI", targets: ["PeerModerationUI"]),
    ],
    dependencies: [
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "TelegramCore", path: "../../submodules/telegram-ios/submodules/TelegramCore"),
        .package(name: "Postbox", path: "../../submodules/telegram-ios/submodules/Postbox"),
        .package(name: "rnoise", path: "../../submodules/telegram-ios/third-party/rnnoise"),
    ] + deps.map { .package(name: $0.0, path: $0.1) },
    targets: [
        .target(
            name: "PeerModerationUI",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "TelegramCore", package: "TelegramCore", condition: nil),
                .product(name: "Postbox", package: "Postbox", condition: nil),
            ] + deps.map { .product(name: $0.0, package: $0.0, condition: nil) },
            path: "Sources/PeerModerationUI"),
        .testTarget(
            name: "PeerModerationUITests",
            dependencies: [
                "PeerModerationUI",
                .product(name: "TGUIKit", package: "TGUIKit"),
                .product(name: "ChatUI", package: "ChatUI"),
                .product(name: "TelegramCore", package: "TelegramCore"),
                .product(name: "Postbox", package: "Postbox"),
                .product(name: "SwiftSignalKit", package: "SSignalKit"),
                .product(name: "rnoise", package: "rnoise"),
            ],
            path: "Tests/PeerModerationUITests",
            linkerSettings: [.unsafeFlags(coreLinkerFlags)]),
    ]
)
