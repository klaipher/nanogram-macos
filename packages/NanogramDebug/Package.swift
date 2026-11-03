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
        .library(name: "NanogramDebugUI", targets: ["NanogramDebugUI", "NanogramLogExport"]),
    ],
    dependencies: [
        .package(name: "Zip", path: "../../submodules/Zip"),
    ],
    targets: [
        .target(name: "NanogramDebug", path: "Sources/NanogramDebug", swiftSettings: nanogramSwiftSettings),
        .target(name: "NanogramLogExport", dependencies: [.product(name: "Zip", package: "Zip")], path: "Sources/NanogramLogExport", swiftSettings: appKitSwiftSettings),
        .target(name: "NanogramDebugUI", dependencies: ["NanogramDebug", "NanogramLogExport"], path: "Sources/NanogramDebugUI", swiftSettings: appKitSwiftSettings),
        .testTarget(name: "NanogramDebugTests", dependencies: ["NanogramDebug", "NanogramDebugUI", "NanogramLogExport"], path: "Tests/NanogramDebugTests", swiftSettings: appKitSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
