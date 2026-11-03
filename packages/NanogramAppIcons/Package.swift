// swift-tools-version:6.2

import PackageDescription

let nanogramSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "NanogramAppIcons",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "NanogramAppIcons", targets: ["NanogramAppIcons"]),
    ],
    targets: [
        .target(
            name: "NanogramAppIcons",
            path: "Sources/NanogramAppIcons",
            resources: [.copy("Icons")],
            swiftSettings: nanogramSwiftSettings),
        .testTarget(
            name: "NanogramAppIconsTests",
            dependencies: ["NanogramAppIcons"],
            path: "Tests/NanogramAppIconsTests",
            swiftSettings: nanogramSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
