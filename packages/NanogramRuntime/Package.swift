// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "NanogramRuntime",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "NanogramRuntime", targets: ["NanogramRuntime"]),
    ],
    targets: [
        .target(name: "NanogramRuntime", path: "Sources/NanogramRuntime", linkerSettings: [.linkedFramework("IOKit")]),
        .testTarget(name: "NanogramRuntimeTests", dependencies: ["NanogramRuntime"], path: "Tests/NanogramRuntimeTests"),
    ]
)
