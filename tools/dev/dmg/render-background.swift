import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width: CGFloat = 640
let height: CGFloat = 400
let canvasWidth: CGFloat = 2560
let canvasHeight: CGFloat = 1600
let appCenter = CGPoint(x: 160, y: 190)
let applicationsCenter = CGPoint(x: 480, y: 190)
let hintCenterY: CGFloat = 336
let hint = "Drag Nanogram to Applications to install"

func required<T>(_ value: T?, _ what: String) -> T {
    guard let value else {
        fatalError("could not create \(what)")
    }
    return value
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func flipped(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x, y: canvasHeight - point.y)
}

func drawBase(_ context: CGContext, space: CGColorSpace) {
    let base = required(CGGradient(colorsSpace: space, colors: [color(0x6E7C94), color(0x67758D)] as CFArray,
                                   locations: [0, 1]), "base gradient")
    context.drawLinearGradient(base, start: flipped(.zero), end: flipped(CGPoint(x: 0, y: height)),
                               options: [.drawsAfterEndLocation])
}

func drawComet(_ context: CGContext, space: CGColorSpace) {
    let head = flipped(CGPoint(x: 588, y: 60))
    let tailEnd = flipped(CGPoint(x: 372, y: 20))
    let radius: CGFloat = 15
    let glow = required(CGGradient(colorsSpace: space, colors: [color(0x508FFF, 0.45), color(0x508FFF, 0)] as CFArray,
                                   locations: [0, 1]), "glow gradient")
    context.drawRadialGradient(glow, startCenter: head, startRadius: 0, endCenter: head, endRadius: 130, options: [])

    let dx = tailEnd.x - head.x
    let dy = tailEnd.y - head.y
    let length = (dx * dx + dy * dy).squareRoot()
    let normal = CGPoint(x: -dy / length * radius, y: dx / length * radius)
    context.saveGState()
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: head.x + normal.x, y: head.y + normal.y))
    tail.addLine(to: tailEnd)
    tail.addLine(to: CGPoint(x: head.x - normal.x, y: head.y - normal.y))
    tail.closeSubpath()
    context.addPath(tail)
    context.clip()
    let streak = required(CGGradient(colorsSpace: space, colors: [color(0x8DB4FF, 0.8), color(0x8DB4FF, 0)] as CFArray,
                                     locations: [0, 1]), "tail gradient")
    context.drawLinearGradient(streak, start: head, end: tailEnd, options: [])
    context.restoreGState()

    context.setFillColor(color(0x508FFF))
    context.fillEllipse(in: CGRect(x: head.x - radius, y: head.y - radius, width: radius * 2, height: radius * 2))
}

func drawArrow(_ context: CGContext) {
    let start = flipped(CGPoint(x: appCenter.x + 96, y: appCenter.y))
    let end = flipped(CGPoint(x: applicationsCenter.x - 96, y: applicationsCenter.y))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: color(0x111722, 0.35))
    context.setStrokeColor(color(0xFFFFFF, 0.9))
    context.setLineWidth(5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineDash(phase: 0, lengths: [0.01, 13])
    context.move(to: start)
    context.addLine(to: CGPoint(x: end.x - 10, y: end.y))
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])
    context.move(to: CGPoint(x: end.x - 15, y: end.y + 15))
    context.addLine(to: end)
    context.addLine(to: CGPoint(x: end.x - 15, y: end.y - 15))
    context.strokePath()
    context.restoreGState()
}

func drawHint(_ context: CGContext) {
    let font = required(CTFontCreateUIFontForLanguage(.emphasizedSystem, 13, nil), "font")
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0xFFFFFF),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: hint, attributes: attributes))
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    let center = flipped(CGPoint(x: width / 2, y: hintCenterY))
    let pill = CGRect(x: center.x - textWidth / 2 - 18, y: center.y - 15, width: textWidth + 36, height: 30)
    context.addPath(CGPath(roundedRect: pill, cornerWidth: 15, cornerHeight: 15, transform: nil))
    context.setFillColor(color(0x111722, 0.42))
    context.fillPath()
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: center.x - textWidth / 2, y: center.y - (ascent - descent) / 2)
    CTLineDraw(line, context)
}

func render(scale: Int) -> CGImage {
    let space = required(CGColorSpace(name: CGColorSpace.sRGB), "sRGB color space")
    let context = required(CGContext(data: nil, width: Int(canvasWidth) * scale, height: Int(canvasHeight) * scale,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), "bitmap context")
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    drawBase(context, space: space)
    drawComet(context, space: space)
    drawArrow(context)
    drawHint(context)
    return required(context.makeImage(), "image")
}

func writePNG(_ image: CGImage, scale: Int, to url: URL) {
    let destination = required(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil),
                               "PNG destination")
    let dpi = 72 * scale
    let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(url.path)")
    }
}

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    do {
        try process.run()
    } catch {
        fatalError("\(tool) failed: \(error)")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("\(tool) exited with \(process.terminationStatus)")
    }
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let output = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1])
    : here.appendingPathComponent("background.tiff")
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nanogram-dmg-\(getpid())")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let oneX = scratch.appendingPathComponent("background.png")
let twoX = scratch.appendingPathComponent("background@2x.png")
writePNG(render(scale: 1), scale: 1, to: oneX)
writePNG(render(scale: 2), scale: 2, to: twoX)
run("/usr/bin/tiffutil", ["-cathidpicheck", oneX.path, twoX.path, "-out", output.path])
print("wrote \(output.path)")
