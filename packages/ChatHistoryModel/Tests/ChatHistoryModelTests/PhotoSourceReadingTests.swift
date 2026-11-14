import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ChatHistoryModel

final class PhotoSourceReadingTests: XCTestCase {
    private var created: [URL] = []

    override func tearDown() {
        created.forEach { try? FileManager.default.removeItem(at: $0) }
        created = []
        super.tearDown()
    }

    private func writeImage(width: Int, height: Int, type: UTType) throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for index in 0 ..< 8 {
            context.setFillColor(red: CGFloat(index) / 8, green: 0.4, blue: 1 - CGFloat(index) / 8, alpha: 1)
            context.fill(CGRect(x: index * width / 8, y: 0, width: width / 8 + 1, height: height))
        }
        let image = try XCTUnwrap(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "bin")")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        created.append(url)
        return url
    }

    private func pixels(_ image: CGImage) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    func testURLThumbnailMatchesDataThumbnail() throws {
        let url = try writeImage(width: 640, height: 480, type: .jpeg)
        let dataSource = try XCTUnwrap(CGImageSourceCreateWithData(try Data(contentsOf: url) as CFData, nil))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 200,
            kCGImageSourceCreateThumbnailFromImageAlways: true
        ]
        let expected = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(dataSource, 0, options as CFDictionary))
        let source = try XCTUnwrap(PhotoSourceReading.source(at: url.path))
        let actual = try XCTUnwrap(PhotoSourceReading.thumbnail(of: source, maxPixelSize: 200))
        XCTAssertEqual(actual.width, expected.width)
        XCTAssertEqual(actual.height, expected.height)
        XCTAssertEqual(pixels(actual), pixels(expected))
    }

    func testMissingFileHasNoSource() {
        XCTAssertNil(PhotoSourceReading.source(at: "/nonexistent/\(UUID().uuidString).jpg"))
    }
}
