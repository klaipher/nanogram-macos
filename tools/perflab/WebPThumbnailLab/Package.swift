// swift-tools-version:5.5

import PackageDescription

let core = "../../../core-xprojects"

let package = Package(
    name: "WebPThumbnailLab",
    platforms: [.macOS(.v11)],
    dependencies: [
        .package(name: "libwebp", path: "../../../submodules/libwebp"),
    ],
    targets: [
        .testTarget(
            name: "WebPThumbnailTests",
            dependencies: [.product(name: "libwebp", package: "libwebp")],
            path: "Tests/WebPThumbnailTests",
            linkerSettings: [
                .unsafeFlags(["-L\(core)/libwebp/build/arm64", "-lwebp", "-lwebpdemux", "-lsharpyuv"]),
                .linkedFramework("Accelerate"),
            ]),
    ]
)
