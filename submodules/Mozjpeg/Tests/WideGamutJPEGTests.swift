import Foundation
import CoreGraphics
import ImageIO
import XCTest
import Mozjpeg

private func makeImage(colorSpace: CGColorSpace, width: Int = 64, height: Int = 64) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [1.0, 0.0, 0.0, 1.0])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    for x in 0 ..< width {
        let value = CGFloat(x) / CGFloat(width - 1)
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.0, value, 0.0, 1.0])!)
        context.fill(CGRect(x: x, y: height / 2, width: 1, height: height / 2))
    }
    return context.makeImage()!
}

private func decode(_ data: Data) -> (profileName: String?, image: CGImage) {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    return (properties?[kCGImagePropertyProfileName] as? String, CGImageSourceCreateImageAtIndex(source, 0, nil)!)
}

private func hasICCProfile(_ data: Data) -> Bool {
    return data.range(of: "ICC_PROFILE".data(using: .ascii)!) != nil
}

private func pixel(_ image: CGImage, in colorSpace: CGColorSpace, x: Int, y: Int) -> (Int, Int, Int) {
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    return (Int(data[0]), Int(data[1]), Int(data[2]))
}

final class WideGamutJPEGTests: XCTestCase {
    private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    override func tearDown() {
        setJPEGPreservesWideGamut(false)
        super.tearDown()
    }

    func testPreservationIsOffByDefault() throws {
        XCTAssertFalse(jpegPreservesWideGamut())
        let data = try XCTUnwrap(compressJPEGData(makeImage(colorSpace: self.displayP3), 90))
        XCTAssertFalse(hasICCProfile(data))
    }

    func testDisplayP3PhotoKeepsItsProfileAndRed() throws {
        setJPEGPreservesWideGamut(true)
        let data = try XCTUnwrap(compressJPEGData(makeImage(colorSpace: self.displayP3), 90))
        let decoded = decode(data)
        XCTAssertTrue(hasICCProfile(data))
        XCTAssertEqual(decoded.profileName, "Display P3")
        let (r, g, b) = pixel(decoded.image, in: self.displayP3, x: 32, y: 56)
        XCTAssertEqual(r, 255, accuracy: 3)
        XCTAssertEqual(g, 0, accuracy: 3)
        XCTAssertEqual(b, 0, accuracy: 3)
    }

    func testSRGBPhotoIsWrittenWithoutAProfile() throws {
        setJPEGPreservesWideGamut(true)
        let data = try XCTUnwrap(compressJPEGData(makeImage(colorSpace: self.sRGB), 90))
        let decoded = decode(data)
        XCTAssertFalse(hasICCProfile(data))
        let (r, g, b) = pixel(decoded.image, in: self.sRGB, x: 32, y: 56)
        XCTAssertEqual(r, 255, accuracy: 3)
        XCTAssertEqual(g, 0, accuracy: 3)
        XCTAssertEqual(b, 0, accuracy: 3)
    }
}
