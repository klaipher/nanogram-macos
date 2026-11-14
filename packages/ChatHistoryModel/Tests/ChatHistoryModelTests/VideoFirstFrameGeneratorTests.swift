import XCTest
import AVFoundation
import CoreVideo
import SwiftSignalKit
@testable import TelegramMediaUtils

@available(macOS 14.0, *)
final class VideoFirstFrameGeneratorTests: XCTestCase {
    private var created: [URL] = []

    override func tearDown() {
        created.forEach { try? FileManager.default.removeItem(at: $0) }
        created = []
        super.tearDown()
    }

    private func writeClip(side: Int, fileType: AVFileType, pathExtension: String?) throws -> URL {
        var name = "frame-\(UUID().uuidString)"
        if let pathExtension {
            name += ".\(pathExtension)"
        }
        let writerURL = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID().uuidString).\(fileType == .mp4 ? "mp4" : "mov")")
        let writer = try AVAssetWriter(outputURL: writerURL, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0 ..< 10 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(index * 20), CVPixelBufferGetBytesPerRow(pixels) * side)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !input.isReadyForMoreMediaData { usleep(1000) }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        input.markAsFinished()
        let done = expectation(description: "written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 30)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: writerURL, to: url)
        created.append(url)
        return url
    }

    func testFirstFrameOfExtensionlessFile() async throws {
        let url = try writeClip(side: 320, fileType: .mp4, pathExtension: nil)
        let image = await VideoFirstFrameGenerator.firstFrame(path: url.path, maxSize: CGSize(width: 800, height: 800), mimeType: "video/mp4")
        XCTAssertEqual(image?.width, 320)
        XCTAssertEqual(image?.height, 320)
    }

    func testFirstFrameRespectsMaximumSize() async throws {
        let url = try writeClip(side: 1200, fileType: .mp4, pathExtension: nil)
        let image = await VideoFirstFrameGenerator.firstFrame(path: url.path, maxSize: CGSize(width: 800, height: 800), mimeType: "video/mp4")
        let frame = try XCTUnwrap(image)
        XCTAssertLessThanOrEqual(max(frame.width, frame.height), 800)
    }

    func testQuickTimeSourceWithMP4Hint() async throws {
        let url = try writeClip(side: 200, fileType: .mov, pathExtension: nil)
        let image = await VideoFirstFrameGenerator.firstFrame(path: url.path, maxSize: CGSize(width: 800, height: 800), mimeType: "video/mp4")
        XCTAssertNotNil(image)
    }

    func testMissingFileGivesNil() async {
        let image = await VideoFirstFrameGenerator.firstFrame(path: "/nonexistent/\(UUID().uuidString)", maxSize: CGSize(width: 800, height: 800), mimeType: "video/mp4")
        XCTAssertNil(image)
    }

    func testSignalDeliversOneImageAndCompletes() throws {
        let url = try writeClip(side: 160, fileType: .mp4, pathExtension: nil)
        let delivered = expectation(description: "delivered")
        let completed = expectation(description: "completed")
        var values = 0
        let disposable = VideoFirstFrameGenerator.signal(path: url.path, maxSize: CGSize(width: 800, height: 800), mimeType: "video/mp4").start(next: { image in
            values += 1
            XCTAssertNotNil(image)
            delivered.fulfill()
        }, completed: {
            completed.fulfill()
        })
        wait(for: [delivered, completed], timeout: 30)
        disposable.dispose()
        XCTAssertEqual(values, 1)
    }

    func testUnsupportedContainerGivesNil() async throws {
        for mime in ["video/webm", "video/x-matroska"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString)")
            try Data(repeating: 0x1A, count: 4096).write(to: url)
            created.append(url)
            let image = await VideoFirstFrameGenerator.firstFrame(path: url.path, maxSize: CGSize(width: 800, height: 800), mimeType: mime)
            XCTAssertNil(image)
        }
    }

    func testDisposeBeforeDeliveryDeliversNothing() throws {
        let url = try writeClip(side: 1200, fileType: .mp4, pathExtension: nil)
        var values = 0
        var completions = 0
        let disposable = VideoFirstFrameGenerator.signal(path: url.path, maxSize: CGSize(width: 800, height: 800), mimeType: "video/mp4").start(next: { _ in
            values += 1
        }, completed: {
            completions += 1
        })
        disposable.dispose()
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settle.fulfill() }
        wait(for: [settle], timeout: 10)
        XCTAssertEqual(values, 0)
        XCTAssertEqual(completions, 0)
    }

    func testDisabledByDefault() {
        XCTAssertFalse(VideoFirstFrameGenerator.isEnabled)
    }
}
