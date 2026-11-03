// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "NanogramRuntime",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "NanogramRuntime", targets: ["NanogramRuntime"]),
    ],
    dependencies: [
        .package(name: "NanogramDebug", path: "../NanogramDebug"),
    ],
    targets: [
        .target(name: "NanogramRuntime", dependencies: [.product(name: "NanogramDebug", package: "NanogramDebug", condition: nil)], path: "Sources/NanogramRuntime", linkerSettings: [.linkedFramework("IOKit")]),
        .testTarget(name: "NanogramRuntimeTests", dependencies: ["NanogramRuntime", .product(name: "NanogramDebug", package: "NanogramDebug", condition: nil)], path: "Tests/NanogramRuntimeTests"),
    ]
)
