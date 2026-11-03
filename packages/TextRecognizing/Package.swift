// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "TextRecognizing",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(
            name: "TextRecognizing",
            targets: ["TextRecognizing"]),
    ],
    dependencies: [
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "libwebp", path: "../../submodules/libwebp"),
    ],
    targets: [
        .target(
            name: "TextRecognizing",
            dependencies: [.product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                           .product(name: "libwebp", package: "libwebp", condition: nil)]),
        .testTarget(
            name: "TextRecognizingTests",
            dependencies: [
                "TextRecognizing",
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
            ],
            path: "Tests/TextRecognizingTests"),
    ]
)
