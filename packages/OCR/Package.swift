// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "OCR",
    products: [
        .library(
            name: "OCR",
            targets: ["OCR"]),
    ],
    dependencies: [
        .package(name: "TGPassportMRZ", path: "../TGPassportMRZ"),
    ],
    targets: [
        .target(
            name: "OCR",
            dependencies: [],
            path: "Sources/OCR"),
        .testTarget(
            name: "OCRTests",
            dependencies: [
                "OCR",
                .product(name: "TGPassportMRZ", package: "TGPassportMRZ"),
            ],
            path: "Tests/OCRTests"),
    ]
)
