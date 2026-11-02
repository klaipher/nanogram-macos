// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "WallpaperBlendLab",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(name: "WallpaperBlendLab", path: "Sources/WallpaperBlendLab"),
    ]
)
