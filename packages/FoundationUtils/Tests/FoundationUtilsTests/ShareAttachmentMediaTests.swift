import XCTest
import ImageIO
import CoreServices
import Darwin
@testable import FoundationUtils

final class ShareAttachmentMediaTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShareAttachmentMediaTests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.directory)
        super.tearDown()
    }

    private func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        return Int64(info.phys_footprint)
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        return context.makeImage()!
    }

    private func write(_ image: CGImage, type: CFString, name: String) -> URL {
        let url = self.directory.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func isJPEG(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) else {
            return false
        }
        return type as String == kUTTypeJPEG as String
    }

    func testALargeFileIsMappedInsteadOfRead() throws {
        let url = self.directory.appendingPathComponent("movie.mp4")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        handle.truncateFile(atOffset: 400 * 1024 * 1024)
        handle.closeFile()

        let before = self.footprint()
        let isImage = ShareAttachmentMedia.imageType(ofFileAt: url) != nil
        let data = ShareAttachmentMedia.fileData(at: url)
        let part = data?.subdata(in: 0 ..< 512 * 1024)
        let after = self.footprint()

        XCTAssertFalse(isImage)
        XCTAssertEqual(data?.count, 400 * 1024 * 1024)
        XCTAssertEqual(part?.count, 512 * 1024)
        XCTAssertLessThan(after - before, 4 * 1024 * 1024, "footprint grew by \(after - before) bytes")
        withExtendedLifetime(data) {}
    }

    func testImagesAreRecognisedFromTheFileHeader() {
        let image = self.makeImage(width: 64, height: 48)
        let jpeg = self.write(image, type: kUTTypeJPEG, name: "photo.jpg")
        let png = self.write(image, type: kUTTypePNG, name: "picture.png")
        let gif = self.write(image, type: kUTTypeGIF, name: "anim.gif")
        let fake = self.directory.appendingPathComponent("not-an-image.jpg")
        FileManager.default.createFile(atPath: fake.path, contents: "plain text".data(using: .utf8))

        XCTAssertEqual(ShareAttachmentMedia.imageType(ofFileAt: jpeg), kUTTypeJPEG as String)
        XCTAssertEqual(ShareAttachmentMedia.imageType(ofFileAt: png), kUTTypePNG as String)
        XCTAssertEqual(ShareAttachmentMedia.imageType(ofFileAt: gif), kUTTypeGIF as String)
        XCTAssertNil(ShareAttachmentMedia.imageType(ofFileAt: fake))
        XCTAssertNil(ShareAttachmentMedia.imageType(of: "plain text".data(using: .utf8)!))
    }

    func testALargePhotoFileIsDownsampledTo1280() throws {
        let url = self.write(self.makeImage(width: 4000, height: 3000), type: kUTTypeJPEG, name: "big.jpg")
        let data = try XCTUnwrap(ShareAttachmentMedia.downsampledJPEG(fileAt: url))
        XCTAssertTrue(self.isJPEG(data))
        XCTAssertEqual(self.pixelSize(data), CGSize(width: 1280, height: 960))
    }

    func testPhotoDataIsDownsampledTo1280() throws {
        let url = self.write(self.makeImage(width: 3000, height: 4000), type: kUTTypePNG, name: "tall.png")
        let data = try XCTUnwrap(ShareAttachmentMedia.downsampledJPEG(data: try Data(contentsOf: url)))
        XCTAssertTrue(self.isJPEG(data))
        XCTAssertEqual(self.pixelSize(data), CGSize(width: 960, height: 1280))
    }

    func testAnInMemoryImageIsEncodedAsADownsampledJPEG() throws {
        let data = try XCTUnwrap(ShareAttachmentMedia.downsampledJPEG(image: self.makeImage(width: 4000, height: 3000)))
        XCTAssertTrue(self.isJPEG(data))
        XCTAssertEqual(self.pixelSize(data), CGSize(width: 1280, height: 960))
        XCTAssertLessThan(data.count, 2 * 1024 * 1024)
    }

    func testASmallImageKeepsItsSize() throws {
        let data = try XCTUnwrap(ShareAttachmentMedia.downsampledJPEG(image: self.makeImage(width: 640, height: 480)))
        XCTAssertEqual(self.pixelSize(data), CGSize(width: 640, height: 480))
    }
}
