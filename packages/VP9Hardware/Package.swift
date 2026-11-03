// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "VP9Hardware",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "VP9Hardware", targets: ["VP9Hardware"]),
    ],
    dependencies: [
        .package(name: "YuvConversion", path: "../../submodules/telegram-ios/submodules/YuvConversion"),
    ],
    targets: [
        .target(
            name: "VP9Hardware",
            dependencies: [.product(name: "YuvConversion", package: "YuvConversion")],
            path: "Sources/VP9Hardware",
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Accelerate"),
            ]),
        .testTarget(
            name: "VP9HardwareTests",
            dependencies: ["VP9Hardware"],
            path: "Tests/VP9HardwareTests",
            resources: [.copy("Resources")]),
    ]
)
