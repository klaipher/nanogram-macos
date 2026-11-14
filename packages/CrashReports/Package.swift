// swift-tools-version:5.9

import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "CrashReports",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "CrashReports", targets: ["CrashReports"]),
    ],
    dependencies: [
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
    ],
    targets: [
        .target(
            name: "CrashReports",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
            ],
            path: "Sources/CrashReports",
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "CrashReportsTests",
            dependencies: ["CrashReports"],
            path: "Tests/CrashReportsTests"),
    ]
)
