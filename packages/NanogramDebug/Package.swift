// swift-tools-version:6.2

import PackageDescription

let nanogramSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]
let appKitSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
]

let package = Package(
    name: "NanogramDebug",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "NanogramDebug", targets: ["NanogramDebug"]),
        .library(name: "NanogramDebugUI", targets: ["NanogramDebugUI"]),
    ],
    targets: [
        .target(name: "NanogramDebug", path: "Sources/NanogramDebug", swiftSettings: nanogramSwiftSettings),
        .target(name: "NanogramDebugUI", dependencies: ["NanogramDebug"], path: "Sources/NanogramDebugUI", swiftSettings: appKitSwiftSettings),
        .testTarget(name: "NanogramDebugTests", dependencies: ["NanogramDebug", "NanogramDebugUI"], path: "Tests/NanogramDebugTests", swiftSettings: appKitSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
