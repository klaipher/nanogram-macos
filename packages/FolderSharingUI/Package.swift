// swift-tools-version:5.5

import PackageDescription
import Foundation

let coreLibraries: [(path: String, name: String)] = [
    ("webrtc/build/webrtc", "mac_framework_objc_static"),
    ("openssl/build/openssl/lib", "ssl"),
    ("openssl/build/openssl/lib", "crypto"),
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

let package = Package(
    name: "FolderSharingUI",
    platforms: [.macOS(.v10_13)],
    products: [.library(name: "FolderSharingUI", targets: ["FolderSharingUI"])],
    dependencies: [
        .package(name: "InputDataUI", path: "../InputDataUI"),
        .package(name: "GeneralRows", path: "../GeneralRows"),
        .package(name: "TelegramContext", path: "../TelegramContext"),
        .package(name: "TelegramTheme", path: "../TelegramTheme"),
        .package(name: "Localization", path: "../Localization"),
        .package(name: "TGUIKit", path: "../TGUIKit"),
        .package(name: "AppAnalytics", path: "../AppAnalytics"),
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "TelegramCore", path: "../../submodules/telegram-ios/submodules/TelegramCore"),
        .package(name: "Postbox", path: "../../submodules/telegram-ios/submodules/Postbox"),
        .package(name: "rnoise", path: "../../submodules/telegram-ios/third-party/rnnoise")
    ],
    targets: [
        .target(name: "FolderSharingUI", dependencies: [
            .product(name: "InputDataUI", package: "InputDataUI"),
            .product(name: "GeneralRows", package: "GeneralRows"),
            .product(name: "TelegramContext", package: "TelegramContext"),
            .product(name: "TelegramTheme", package: "TelegramTheme"),
            .product(name: "Localization", package: "Localization"),
            .product(name: "TGUIKit", package: "TGUIKit"),
            .product(name: "AppAnalytics", package: "AppAnalytics"),
            .product(name: "SwiftSignalKit", package: "SSignalKit"),
            .product(name: "TelegramCore", package: "TelegramCore"),
            .product(name: "Postbox", package: "Postbox")
        ]),
        .testTarget(name: "FolderSharingUITests", dependencies: ["FolderSharingUI", .product(name: "rnoise", package: "rnoise")], linkerSettings: [.unsafeFlags(coreLinkerFlags)])
    ]
)
