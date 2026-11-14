// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "WalletEngine",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(
            name: "WalletEngineFFI",
            targets: ["WalletEngineFFI"]),
    ],
    dependencies: [
        .package(name: "RustLibraries", path: "../RustLibraries"),
    ],
    targets: [
        .target(
            name: "WalletEngineFFI",
            dependencies: [.product(name: "NanogramRustFFI", package: "RustLibraries")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "WalletEngineFFITests",
            dependencies: ["WalletEngineFFI"]
        ),
    ]
)
