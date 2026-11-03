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
let coreXprojects = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../core-xprojects").standardized
let coreLinkerFlags: [String] = coreLibraries.flatMap { ["-L", coreXprojects.appendingPathComponent($0.path).path, "-l\($0.name)"] }

let package = Package(
    name: "LottieCacheLab",
    platforms: [.macOS(.v11)],
    dependencies: [
        .package(name: "TelegramMedia", path: "../../../packages/TelegramMedia"),
        .package(name: "TelegramMediaPlayer", path: "../../../submodules/telegram-ios/submodules/MediaPlayer"),
        .package(name: "SSignalKit", path: "../../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "rnoise", path: "../../../submodules/telegram-ios/third-party/rnnoise"),
    ],
    targets: [
        .testTarget(
            name: "LottieCacheTests",
            dependencies: [
                .product(name: "TelegramMedia", package: "TelegramMedia"),
                .product(name: "TelegramMediaPlayer", package: "TelegramMediaPlayer"),
                .product(name: "SwiftSignalKit", package: "SSignalKit"),
                .product(name: "rnoise", package: "rnoise"),
            ],
            path: "Tests/LottieCacheTests",
            linkerSettings: [
                .unsafeFlags(coreLinkerFlags),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("c++"),
            ]),
    ]
)
