// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "ChatAppIntents",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "ChatAppIntents", targets: ["ChatAppIntents"]),
    ],
    targets: [
        .target(
            name: "ChatAppIntents",
            path: "Sources/ChatAppIntents"),
        .testTarget(
            name: "ChatAppIntentsTests",
            dependencies: ["ChatAppIntents"],
            path: "Tests/ChatAppIntentsTests"),
    ]
)
