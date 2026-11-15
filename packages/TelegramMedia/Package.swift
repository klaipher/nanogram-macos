// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// The native libraries the TelegramMedia tests link (the same set as the ChatUI tests); build them with `tg frameworks`.
let testLibraries: [(path: String, name: String)] = [
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
    ("libwebp/build/libwebp/lib", "webp"),
    ("libwebp/build/libwebp/lib", "webpdemux"),
    ("libwebp/build/libwebp/lib", "sharpyuv"),
    ("tde2e/build/tde2e/lib", "tde2e"),
    ("tde2e/build/tde2e/lib", "tdutils"),
]
let testLinkerFlags: [String] = testLibraries.flatMap { ["-L", "../../core-xprojects/" + $0.path, "-l" + $0.name] }

let package = Package(
    name: "TelegramMedia",
    platforms: [.macOS(.v10_13)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "TelegramMedia",
            targets: ["TelegramMedia"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "TelegramCore", path: "../../submodules/telegram-ios/submodules/TelegramCore"),
        .package(name: "Postbox", path: "../../submodules/telegram-ios/submodules/Postbox"),
        .package(name: "OpusBinding", path: "../../submodules/telegram-ios/submodules/OpusBinding"),
        .package(name: "TelegramVoip", path: "../../submodules/telegram-ios/submodules/TelegramVoip"),
        .package(name: "GZIP", path: "../GZIP"),
        .package(name: "VP9Hardware", path: "../VP9Hardware"),
        .package(name: "TGUIKit", path: "../TGUIKit"),
        .package(name: "libwebp", path: "../../submodules/libwebp"),
        .package(name: "ApiCredentials", path: "../ApiCredentials"),
        .package(name: "ObjcUtils", path: "../ObjcUtils"),
        .package(name: "TelegramMediaResources", path: "../TelegramMediaResources"),
        .package(name: "TelegramMediaPlayer", path: "../../submodules/telegram-ios/submodules/MediaPlayer"),
        .package(name: "VoiceRecorderInput", path: "../VoiceRecorderInput"),
        .package(name: "NanogramRuntime", path: "../NanogramRuntime"),
        .package(name: "HLSPlayback", path: "../HLSPlayback"),
        .package(name: "rnoise", path: "../../submodules/telegram-ios/third-party/rnnoise"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "TelegramMedia",
            dependencies: [.product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                           .product(name: "TGUIKit", package: "TGUIKit", condition: nil),
                           .product(name: "TelegramCore", package: "TelegramCore", condition: nil),
                           .product(name: "GZIP", package: "GZIP", condition: nil),
                           .product(name: "VP9Hardware", package: "VP9Hardware", condition: nil),
                           .product(name: "Postbox", package: "Postbox", condition: nil),
                           .product(name: "libwebp", package: "libwebp", condition: nil),
                           .product(name: "ApiCredentials", package: "ApiCredentials", condition: nil),
                           .product(name: "ObjcUtils", package: "ObjcUtils", condition: nil),
                           .product(name: "TelegramMediaResources", package: "TelegramMediaResources", condition: nil),
                           .product(name: "TelegramMediaPlayer", package: "TelegramMediaPlayer", condition: nil),
                           .product(name: "OpusBinding", package: "OpusBinding", condition: nil),
                           .product(name: "TelegramVoip", package: "TelegramVoip", condition: nil),
                           .product(name: "VoiceRecorderInput", package: "VoiceRecorderInput", condition: nil),
                           .product(name: "NanogramRuntime", package: "NanogramRuntime", condition: nil),
                           .product(name: "HLSPlayback", package: "HLSPlayback", condition: nil),
                          ],
            path: "Sources"),
        // Frame cache, tinted emoji cache, webm decoder, GIF tile pool and chunk player tests (from the former
        // tools/perflab/LottieCacheLab).
        .testTarget(
            name: "TelegramMediaTests",
            dependencies: [
                "TelegramMedia",
                .product(name: "TelegramMediaPlayer", package: "TelegramMediaPlayer", condition: nil),
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "TGUIKit", package: "TGUIKit", condition: nil),
                .product(name: "rnoise", package: "rnoise", condition: nil),
            ],
            path: "Tests/TelegramMediaTests",
            linkerSettings: [
                .unsafeFlags(testLinkerFlags),
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
