// swift-tools-version:6.2

import PackageDescription

let nanogramSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "NanogramDecoder",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NanogramDecoder", targets: ["NanogramDecoder"]),
    ],
    targets: [
        .target(
            name: "NanogramDecoder",
            path: "Sources/NanogramDecoder",
            swiftSettings: nanogramSwiftSettings),
        .testTarget(
            name: "NanogramDecoderTests",
            dependencies: ["NanogramDecoder"],
            path: "Tests/NanogramDecoderTests",
            swiftSettings: nanogramSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
