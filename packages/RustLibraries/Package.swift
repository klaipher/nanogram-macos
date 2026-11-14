// swift-tools-version:5.5

import PackageDescription

// One static library for the three Rust libraries (tlottie, mtproto-engine, wallet-engine), built by
// core-xprojects/nanogram-rust. It carries the clang modules wallet_engineFFI and MTProtoEngineFFI.
let package = Package(
    name: "RustLibraries",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "NanogramRustFFI", targets: ["NanogramRustFFI"]),
    ],
    targets: [
        .binaryTarget(
            name: "NanogramRustFFI",
            path: "NanogramRustFFI.xcframework"
        ),
    ]
)
