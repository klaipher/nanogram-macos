// Renders nanogram/icon/NanogramComet.svg (the dark Comet) into the macOS icons upstream ships as PNGs:
// Telegram-Mac/Assets.xcassets/AppIcon.appiconset/Logo_*.png (the icon before macOS 26, which uses
// Telegram-Mac/AppIcon.icon) and TelegramShare/icon.icns. Re-run after changing the source:
//   swift tools/dev/nanogram/render-mac-icon.swift
// Port of the iOS fork's AlternateIconSources/render.swift: QuickLook (WebKit) rasterises the full-bleed SVG,
// then each size is drawn into Apple's macOS icon grid (824 pt rounded square centred on a 1024 pt canvas,
// transparent margin, soft drop shadow).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func required<T>(_ value: T?, _ what: String) -> T {
    guard let value else {
        fatalError("could not create \(what)")
    }
    return value
}

func attempt<T>(_ what: String, _ body: () throws -> T) -> T {
    do {
        return try body()
    } catch {
        fatalError("\(what) failed: \(error)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("nanogram/icon/NanogramComet.svg")
let appIconSet = root.appendingPathComponent("Telegram-Mac/Assets.xcassets/AppIcon.appiconset")
let shareIcon = root.appendingPathComponent("TelegramShare/icon.icns")

// Logo_<file>.png names in AppIcon.appiconset/Contents.json, by pixel size.
let appIconFiles: [(file: String, pixels: Int)] = [
    ("Logo_16", 16), ("Logo_32", 32), ("Logo_32-1", 32), ("Logo_64", 64), ("Logo_128", 128),
    ("Logo_256", 256), ("Logo_256-1", 256), ("Logo_512", 512), ("Logo_512-1", 512), ("Logo_1024", 1024),
]
let iconsetFiles: [(file: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    attempt(tool) { try process.run() }
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "\(tool) exited with \(process.terminationStatus)")
}

func rasterize(_ svg: URL, into dir: URL) -> CGImage {
    run("/usr/bin/qlmanage", ["-t", "-s", "1024", "-o", dir.path, svg.path])
    let png = dir.appendingPathComponent(svg.lastPathComponent + ".png")
    guard let source = CGImageSourceCreateWithURL(png as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("QuickLook did not render \(svg.lastPathComponent)")
    }
    return image
}

func writeMacIcon(_ artwork: CGImage, pixels: Int, to url: URL) {
    let scale = CGFloat(pixels) / 1024
    let space = required(CGColorSpace(name: CGColorSpace.sRGB), "sRGB colour space")
    let context = required(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "bitmap context")
    context.interpolationQuality = .high
    context.scaleBy(x: scale, y: scale)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)
    if pixels >= 64 {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(colorSpace: space, components: [0, 0, 0, 0.3]))
        context.addPath(shape)
        context.setFillColor(CGColor(colorSpace: space, components: [0.06667, 0.09020, 0.13333, 1])!)
        context.fillPath()
        context.restoreGState()
    }
    context.addPath(shape)
    context.clip()
    context.draw(artwork, in: body)
    let destination = required(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil), "PNG writer")
    CGImageDestinationAddImage(destination, required(context.makeImage(), "image"), nil)
    precondition(CGImageDestinationFinalize(destination), "could not write \(url.path)")
}

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("nanogram-icon-\(UUID().uuidString)")
attempt("temp folder") { try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true) }
defer { try? FileManager.default.removeItem(at: temp) }

let artwork = rasterize(source, into: temp)
for icon in appIconFiles {
    writeMacIcon(artwork, pixels: icon.pixels, to: appIconSet.appendingPathComponent("\(icon.file).png"))
}
let iconset = temp.appendingPathComponent("icon.iconset")
attempt("iconset folder") { try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true) }
for icon in iconsetFiles {
    writeMacIcon(artwork, pixels: icon.pixels, to: iconset.appendingPathComponent("\(icon.file).png"))
}
run("/usr/bin/iconutil", ["-c", "icns", "-o", shareIcon.path, iconset.path])
print("AppIcon.appiconset: \(appIconFiles.count) PNGs; TelegramShare/icon.icns: \(iconsetFiles.count) sizes")
