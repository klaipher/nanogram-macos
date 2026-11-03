// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "NanogramDebug",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "NanogramDebug", targets: ["NanogramDebug"]),
        .library(name: "NanogramDebugUI", targets: ["NanogramDebugUI"]),
    ],
    targets: [
        .target(name: "NanogramDebug", path: "Sources/NanogramDebug"),
        .target(name: "NanogramDebugUI", dependencies: ["NanogramDebug"], path: "Sources/NanogramDebugUI"),
        .testTarget(name: "NanogramDebugTests", dependencies: ["NanogramDebug", "NanogramDebugUI"], path: "Tests/NanogramDebugTests"),
    ]
)
