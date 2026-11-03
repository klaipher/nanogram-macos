import CoreGraphics
import Foundation

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

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("Telegram-Mac/Assets.xcassets/Icon_NanogramComet.imageset/NanogramComet.pdf")

let side: CGFloat = 140
let artwork: CGFloat = 1024
var mediaBox = CGRect(x: 0, y: 0, width: side, height: side)
let space = required(CGColorSpace(name: CGColorSpace.sRGB), "sRGB color space")
let context = required(CGContext(output as CFURL, mediaBox: &mediaBox, [kCGPDFContextCreator: "render-comet-badge.swift"] as CFDictionary), "PDF context")
context.beginPDFPage(nil)
context.translateBy(x: 0, y: side)
context.scaleBy(x: side / artwork, y: -side / artwork)
context.addEllipse(in: CGRect(x: 0, y: 0, width: artwork, height: artwork))
context.clip()
context.setFillColor(color(0x111722))
context.fill(CGRect(x: 0, y: 0, width: artwork, height: artwork))
context.saveGState()
context.move(to: CGPoint(x: 752, y: 550))
context.addLine(to: CGPoint(x: 176, y: 848))
context.addLine(to: CGPoint(x: 474, y: 272))
context.closePath()
context.clip()
let tail = required(CGGradient(colorsSpace: space, colors: [color(0x4D89F4), color(0x111722)] as CFArray,
                               locations: [0, 1]), "tail gradient")
context.drawLinearGradient(tail, start: CGPoint(x: 613, y: 411), end: CGPoint(x: 176, y: 848),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
context.restoreGState()
context.setFillColor(color(0x508FFF))
context.fillEllipse(in: CGRect(x: 613 - 196, y: 411 - 196, width: 392, height: 392))
context.endPDFPage()
context.closePDF()
print("wrote \(output.path)")
