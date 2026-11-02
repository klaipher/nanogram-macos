// swift-tools-version:6.2

import PackageDescription

let nanogramSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "NanogramKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NanogramKit", targets: ["NanogramKit"]),
    ],
    targets: [
        .target(
            name: "NanogramKit",
            path: "Sources/NanogramKit",
            swiftSettings: nanogramSwiftSettings),
        .testTarget(
            name: "NanogramKitTests",
            dependencies: ["NanogramKit"],
            path: "Tests/NanogramKitTests",
            swiftSettings: nanogramSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
