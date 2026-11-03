// Renders Nanogram's macOS icons from the SVGs in nanogram/icon (the iOS fork's AlternateIconSources, plus Classic,
// Dash, Forward and Streak redrawn from its PNGs). Re-run after changing a source:
//   swift tools/dev/nanogram/render-mac-icon.swift
// Writes:
// - Telegram-Mac/Assets.xcassets/AppIcon.appiconset/Logo_*.png (the icon before macOS 26, which uses
//   Telegram-Mac/AppIcon.icon) and TelegramShare/icon.icns, from NanogramComet.svg (the dark Comet);
// - packages/NanogramAppIcons/Sources/NanogramAppIcons/Icons/<Name>.icns, every icon of the app icon picker
//   (16 to 1024 px, so Finder's large icon view, Gallery and Quick Look stay sharp);
// - Telegram-Mac/Assets.xcassets/StatusIcon.imageset (the menu bar glyph) and Icon_TelegramLogin.imageset
//   (the share extension's sign-in logo).
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
let sources = root.appendingPathComponent("nanogram/icon")
let defaultIconName = "NanogramComet"
let assets = root.appendingPathComponent("Telegram-Mac/Assets.xcassets")
let appIconSet = assets.appendingPathComponent("AppIcon.appiconset")
let shareIcon = root.appendingPathComponent("TelegramShare/icon.icns")
let pickerIcons = root.appendingPathComponent("packages/NanogramAppIcons/Sources/NanogramAppIcons/Icons")
let statusIconSet = assets.appendingPathComponent("StatusIcon.imageset")
let shareLoginSet = assets.appendingPathComponent("Icon_TelegramLogin.imageset")

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
let statusIconFiles: [(file: String, pixels: Int)] = [("StatusIcon", 16), ("StatusIcon@2x", 32)]
let shareLoginFiles: [(file: String, pixels: Int)] = [("TelegramIcon", 80), ("TelegramIcon@2x", 160)]

let space = required(CGColorSpace(name: CGColorSpace.sRGB), "sRGB colour space")

func color(_ components: [CGFloat]) -> CGColor {
    required(CGColor(colorSpace: space, components: components), "colour")
}

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

func makeContext(pixels: Int) -> CGContext {
    let context = required(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "bitmap context")
    context.interpolationQuality = .high
    return context
}

func writePNG(_ context: CGContext, to url: URL) {
    let destination = required(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil), "PNG writer")
    CGImageDestinationAddImage(destination, required(context.makeImage(), "image"), nil)
    precondition(CGImageDestinationFinalize(destination), "could not write \(url.path)")
}

func writeMacIcon(_ artwork: CGImage, pixels: Int, to url: URL) {
    let context = makeContext(pixels: pixels)
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)
    if pixels >= 64 {
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: color([0, 0, 0, 0.3]))
    }
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.draw(artwork, in: body)
    context.restoreGState()
    context.endTransparencyLayer()
    writePNG(context, to: url)
}

func writeIcns(_ artwork: CGImage, sizes: [(file: String, pixels: Int)], to url: URL, temp: URL) {
    let iconset = temp.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".iconset")
    attempt("iconset folder") { try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true) }
    for icon in sizes {
        writeMacIcon(artwork, pixels: icon.pixels, to: iconset.appendingPathComponent("\(icon.file).png"))
    }
    run("/usr/bin/iconutil", ["-c", "icns", "-o", url.path, iconset.path])
}

func writeCircle(_ artwork: CGImage, pixels: Int, to url: URL) {
    let context = makeContext(pixels: pixels)
    let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    context.addEllipse(in: bounds)
    context.clip()
    context.draw(artwork, in: bounds)
    writePNG(context, to: url)
}

func writeCometGlyph(pixels: Int, to url: URL) {
    let context = makeContext(pixels: pixels)
    let side = CGFloat(pixels)
    let margin = side / 16
    let scale = (side - 2 * margin) / 633
    context.translateBy(x: margin - 176 * scale, y: side - (margin - 215 * scale))
    context.scaleBy(x: scale, y: -scale)
    context.saveGState()
    context.move(to: CGPoint(x: 752, y: 550))
    context.addLine(to: CGPoint(x: 176, y: 848))
    context.addLine(to: CGPoint(x: 474, y: 272))
    context.closePath()
    context.clip()
    let tail = required(CGGradient(colorsSpace: space, colors: [color([0, 0, 0, 1]), color([0, 0, 0, 0.25])] as CFArray, locations: [0, 1]), "gradient")
    context.drawLinearGradient(tail, start: CGPoint(x: 613, y: 411), end: CGPoint(x: 176, y: 848), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    context.setFillColor(color([0, 0, 0, 1]))
    context.fillEllipse(in: CGRect(x: 613 - 196, y: 411 - 196, width: 392, height: 392))
    writePNG(context, to: url)
}

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("nanogram-icon-\(UUID().uuidString)")
attempt("temp folder") { try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true) }
defer { try? FileManager.default.removeItem(at: temp) }
attempt("icons folder") { try FileManager.default.createDirectory(at: pickerIcons, withIntermediateDirectories: true) }

let svgs = attempt("listing sources") { try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) }
    .filter { $0.pathExtension == "svg" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
for svg in svgs {
    let name = svg.deletingPathExtension().lastPathComponent
    let artwork = rasterize(svg, into: temp)
    writeIcns(artwork, sizes: iconsetFiles, to: pickerIcons.appendingPathComponent("\(name).icns"), temp: temp)
    if name == defaultIconName {
        for icon in appIconFiles {
            writeMacIcon(artwork, pixels: icon.pixels, to: appIconSet.appendingPathComponent("\(icon.file).png"))
        }
        writeIcns(artwork, sizes: iconsetFiles, to: shareIcon, temp: temp)
        for icon in shareLoginFiles {
            writeCircle(artwork, pixels: icon.pixels, to: shareLoginSet.appendingPathComponent("\(icon.file).png"))
        }
    }
    print("\(name).icns")
}
for icon in statusIconFiles {
    writeCometGlyph(pixels: icon.pixels, to: statusIconSet.appendingPathComponent("\(icon.file).png"))
}
print("AppIcon.appiconset, TelegramShare/icon.icns, StatusIcon, Icon_TelegramLogin from \(defaultIconName).svg")
