// swift-tools-version:6.2

import PackageDescription

let nanogramSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "ChatAppIntents",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ChatAppIntents", targets: ["ChatAppIntents"]),
    ],
    targets: [
        .target(
            name: "ChatAppIntents",
            path: "Sources/ChatAppIntents",
            swiftSettings: nanogramSwiftSettings),
        .testTarget(
            name: "ChatAppIntentsTests",
            dependencies: ["ChatAppIntents"],
            path: "Tests/ChatAppIntentsTests",
            swiftSettings: nanogramSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
