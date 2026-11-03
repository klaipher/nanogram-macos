// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let callVideoLayerTestLibraries: [(path: String, name: String)] = [
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
]
let callVideoLayerTestLinkerFlags: [String] = callVideoLayerTestLibraries.flatMap { ["-L", "../../core-xprojects/" + $0.path, "-l" + $0.name] }

let package = Package(
    name: "CallVideoLayer",
    platforms: [.macOS(.v10_13)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "CallVideoLayer",
            targets: ["CallVideoLayer"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "MetalEngine", path: "../../submodules/telegram-ios/submodules/MetalEngine"),
        .package(name: "TGUIKit", path: "../TGUIKit"),
        .package(name: "TgVoipWebrtc", path: "../../submodules/tgcalls"),
        .package(name: "TelegramVoip", path: "../../submodules/telegram-ios/submodules/TelegramVoip"),
        .package(name: "YuvConversion", path: "../../submodules/telegram-ios/submodules/YuvConversion"),
        .package(name: "rnoise", path: "../../submodules/telegram-ios/third-party/rnnoise"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "CallVideoLayer",
            dependencies: [.product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                           .product(name: "MetalEngine", package: "MetalEngine", condition: nil),
                           .product(name: "TGUIKit", package: "TGUIKit", condition: nil),
                           .product(name: "TgVoipWebrtc", package: "TgVoipWebrtc", condition: nil),
                           .product(name: "TelegramVoip", package: "TelegramVoip", condition: nil),
                           .product(name: "YuvConversion", package: "YuvConversion", condition: nil)],
            path: "Sources/"),
        .testTarget(
            name: "CallVideoLayerTests",
            dependencies: ["CallVideoLayer", .product(name: "rnoise", package: "rnoise")],
            path: "Tests/CallVideoLayerTests",
            linkerSettings: [
                .unsafeFlags(callVideoLayerTestLinkerFlags),
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
