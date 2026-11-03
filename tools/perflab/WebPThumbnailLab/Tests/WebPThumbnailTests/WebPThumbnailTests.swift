import XCTest
import AppKit
import libwebp

final class WebPThumbnailTests: XCTestCase {
    private func stickerImage(side: Int) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let s = CGFloat(side)
        context.setFillColor(NSColor(deviceRed: 0.95, green: 0.75, blue: 0.2, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84))
        context.setFillColor(NSColor(deviceRed: 0.3, green: 0.15, blue: 0.05, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: s * 0.3, y: s * 0.55, width: s * 0.12, height: s * 0.16))
        context.fillEllipse(in: CGRect(x: s * 0.58, y: s * 0.55, width: s * 0.12, height: s * 0.16))
        context.setStrokeColor(NSColor(deviceRed: 0.8, green: 0.1, blue: 0.2, alpha: 0.8).cgColor)
        context.setLineWidth(s * 0.04)
        context.addArc(center: CGPoint(x: s / 2, y: s * 0.45), radius: s * 0.22, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
        context.strokePath()
        return context.makeImage()!
    }

    private func pixels(_ image: CGImage, side: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return bytes
    }

    private func legacyThumbnail(_ data: Data) -> CGImage? {
        var image = convertFromWebP(data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if image != nil {
            let webp = WebPImageDecoder(data: data, scale: 2.0)
            image = webp?.frame(at: 0, decodeForDisplay: true)?.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? image
        }
        return image
    }

    func testScaledDecodeFitsTheTargetPixelSize() throws {
        let data = try XCTUnwrap(convertToWebP(self.stickerImage(side: 512), 0.9))
        let thumb = try XCTUnwrap(WebPCreateImageFittingPixelSize(data, CGSize(width: 160, height: 160)))
        XCTAssertEqual(thumb.width, 160)
        XCTAssertEqual(thumb.height, 160)
        let full = try XCTUnwrap(WebPCreateImageFittingPixelSize(data, CGSize(width: 1024, height: 1024)))
        XCTAssertEqual(full.width, 512, "never upscales")
        let wide = try XCTUnwrap(WebPCreateImageFittingPixelSize(try XCTUnwrap(convertToWebP(self.stickerImage(side: 300), 0.9)), CGSize(width: 100, height: 60)))
        XCTAssertEqual(wide.width, 60)
        XCTAssertNil(WebPCreateImageFittingPixelSize(Data([1, 2, 3]), CGSize(width: 10, height: 10)))
    }

    func testScaledDecodeMatchesTheLegacyFullSizePath() throws {
        let data = try XCTUnwrap(convertToWebP(self.stickerImage(side: 512), 0.9))
        let side = 160
        let legacy = self.pixels(try XCTUnwrap(self.legacyThumbnail(data)), side: side)
        let scaled = self.pixels(try XCTUnwrap(WebPCreateImageFittingPixelSize(data, CGSize(width: side, height: side))), side: side)
        var total = 0
        var worst = 0
        for i in 0 ..< legacy.count {
            let d = abs(Int(legacy[i]) - Int(scaled[i]))
            total += d
            worst = max(worst, d)
        }
        let mean = Double(total) / Double(legacy.count)
        print(String(format: "WebPThumbnail parity at %dpx: mean |Δ| %.3f, max %d", side, mean, worst))
        XCTAssertLessThan(mean, 2.0)
    }

    func testScaledDecodeIsCheaper() throws {
        let data = try XCTUnwrap(convertToWebP(self.stickerImage(side: 512), 0.9))
        let rounds = 30
        _ = self.legacyThumbnail(data)
        var start = CACurrentMediaTime()
        for _ in 0 ..< rounds {
            _ = self.legacyThumbnail(data)
        }
        let legacy = (CACurrentMediaTime() - start) / Double(rounds) * 1000
        start = CACurrentMediaTime()
        for _ in 0 ..< rounds {
            _ = WebPCreateImageFittingPixelSize(data, CGSize(width: 320, height: 320))
        }
        let scaled = (CACurrentMediaTime() - start) / Double(rounds) * 1000
        print(String(format: "WebPThumbnail 512px sticker: legacy two full decodes %.2f ms, one decode at 320px %.2f ms", legacy, scaled))
        XCTAssertLessThan(scaled, legacy)
    }
}
