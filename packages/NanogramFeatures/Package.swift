// swift-tools-version:5.5

import PackageDescription

// Link hygiene and search operators: the iOS core's NanogramFeatures sources, compiled here through symlinks (one
// implementation for iOS and Mac). The Mac-only glue (debug options, defaults) is in NanogramRuntime.
let package = Package(
    name: "NanogramFeatures",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "NanogramFeatures", targets: ["NanogramFeatures"]),
    ],
    targets: [
        .target(
            name: "NanogramFeatures",
            path: "Sources"),
        .testTarget(
            name: "NanogramFeaturesTests",
            dependencies: ["NanogramFeatures"],
            path: "Tests"),
    ]
)
