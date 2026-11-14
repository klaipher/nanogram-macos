// swift-tools-version:5.5

import PackageDescription

let deps: [(String, String)] = [
    ("AppAnalytics", "../AppAnalytics"),
    ("TGUIKit", "../TGUIKit"),
    ("ColorPalette", "../ColorPalette"),
    ("InAppSettings", "../InAppSettings"),
    ("TelegramTheme", "../TelegramTheme"),
    ("TelegramContext", "../TelegramContext"),
    ("TelegramUtils", "../TelegramUtils"),
    ("TelegramMedia", "../TelegramMedia"),
    ("TelegramMediaUtils", "../TelegramMediaUtils"),
    ("ObjcUtils", "../ObjcUtils"),
    ("TGVideoCameraMovie", "../TGVideoCameraMovie"),
    ("GZIP", "../GZIP"),
]

let mediaRecorderTestLibraries: [(path: String, name: String)] = [
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
let mediaRecorderTestLinkerFlags: [String] = mediaRecorderTestLibraries.flatMap { ["-L", "../../core-xprojects/" + $0.path, "-l" + $0.name] }

let package = Package(
    name: "MediaRecorderUI",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "MediaRecorderUI", targets: ["MediaRecorderUI"]),
    ],
    dependencies: [
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "TelegramCore", path: "../../submodules/telegram-ios/submodules/TelegramCore"),
        .package(name: "Postbox", path: "../../submodules/telegram-ios/submodules/Postbox"),
        .package(name: "rnoise", path: "../../submodules/telegram-ios/third-party/rnnoise"),
    ] + deps.map { .package(name: $0.0, path: $0.1) },
    targets: [
        .target(
            name: "MediaRecorderUI",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "TelegramCore", package: "TelegramCore", condition: nil),
                .product(name: "Postbox", package: "Postbox", condition: nil),
            ] + deps.map { .product(name: $0.0, package: $0.0, condition: nil) },
            path: "Sources/MediaRecorderUI"),
        .testTarget(
            name: "MediaRecorderUITests",
            dependencies: [
                "MediaRecorderUI",
                .product(name: "TGVideoCameraMovie", package: "TGVideoCameraMovie", condition: nil),
                .product(name: "rnoise", package: "rnoise", condition: nil),
            ],
            path: "Tests/MediaRecorderUITests",
            linkerSettings: [
                .unsafeFlags(mediaRecorderTestLinkerFlags),
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
