// swift-tools-version:5.5

import PackageDescription

let imageCanvasTestLibraries: [(path: String, name: String)] = [
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
]
let imageCanvasTestLinkerFlags: [String] = imageCanvasTestLibraries.flatMap { ["-L", "../../core-xprojects/" + $0.path, "-l" + $0.name] }

let package = Package(
    name: "ImageCanvasUI",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "ImageCanvasUI", targets: ["ImageCanvasUI"]),
    ],
    dependencies: [
        .package(name: "FFMpegBinding", path: "../../submodules/telegram-ios/submodules/FFMpegBinding"),
        .package(name: "AppAnalytics", path: "../AppAnalytics"),
        .package(name: "TGUIKit", path: "../TGUIKit"),
        .package(name: "ColorPalette", path: "../ColorPalette"),
        .package(name: "Localization", path: "../Localization"),
        .package(name: "TelegramTheme", path: "../TelegramTheme"),
        .package(name: "TelegramMediaUtils", path: "../TelegramMediaUtils"),
        .package(name: "TelegramMedia", path: "../TelegramMedia"),
        .package(name: "TelegramMediaPlayer", path: "../../submodules/telegram-ios/submodules/MediaPlayer"),
        .package(name: "TelegramContext", path: "../TelegramContext"),
        .package(name: "TextRecognizing", path: "../TextRecognizing"),
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "rnoise", path: "../../submodules/telegram-ios/third-party/rnnoise"),
    ],
    targets: [
        .target(
            name: "ImageCanvasUI",
            dependencies: [
                .product(name: "FFMpegBinding", package: "FFMpegBinding", condition: nil),
                .product(name: "AppAnalytics", package: "AppAnalytics", condition: nil),
                .product(name: "TGUIKit", package: "TGUIKit", condition: nil),
                .product(name: "ColorPalette", package: "ColorPalette", condition: nil),
                .product(name: "Localization", package: "Localization", condition: nil),
                .product(name: "TelegramTheme", package: "TelegramTheme", condition: nil),
                .product(name: "TelegramMediaUtils", package: "TelegramMediaUtils", condition: nil),
                .product(name: "TelegramMedia", package: "TelegramMedia", condition: nil),
                .product(name: "TelegramMediaPlayer", package: "TelegramMediaPlayer", condition: nil),
                .product(name: "TelegramContext", package: "TelegramContext", condition: nil),
                .product(name: "TextRecognizing", package: "TextRecognizing", condition: nil),
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
            ],
            path: "Sources/ImageCanvasUI",
            resources: [.process("Resources/Assets.xcassets")]),
        .testTarget(
            name: "ImageCanvasUITests",
            dependencies: [
                "ImageCanvasUI",
                .product(name: "rnoise", package: "rnoise", condition: nil),
            ],
            path: "Tests/ImageCanvasUITests",
            linkerSettings: [
                .unsafeFlags(imageCanvasTestLinkerFlags),
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
