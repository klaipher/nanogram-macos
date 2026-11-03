import XCTest
import AVFoundation
import SwiftSignalKit
@testable import ImageCanvasUI

final class EditVideoStillTests: XCTestCase {
    private func writeClip(frames: Int, side: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0 ..< frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(index * 8 % 255), CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        let done = self.expectation(description: "written")
        writer.finishWriting { done.fulfill() }
        self.wait(for: [done], timeout: 30)
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    func testTheStillArrivesOnMainAfterTheCallReturned() throws {
        let url = try self.writeClip(frames: 30, side: 256)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)

        var still: CGImage?
        var deliveredOnMain = false
        let arrived = self.expectation(description: "still arrived")
        let disposable = (EditVideoStill.generate(asset: asset, at: CMTime(value: 15, timescale: 30), maximumSide: 1920) |> deliverOnMainQueue).start(next: { image in
            deliveredOnMain = Thread.isMainThread
            still = image
            arrived.fulfill()
        })
        XCTAssertNil(still)
        self.wait(for: [arrived], timeout: 10)
        disposable.dispose()

        XCTAssertTrue(deliveredOnMain)
        let image = try XCTUnwrap(still)
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 256)
    }

    func testAnUnreadableAssetGivesNil() {
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).mov"))
        var result: CGImage?? = .none
        let arrived = self.expectation(description: "result arrived")
        let disposable = EditVideoStill.generate(asset: asset, at: .zero, maximumSide: 1920).start(next: { image in
            result = .some(image)
            arrived.fulfill()
        })
        self.wait(for: [arrived], timeout: 10)
        disposable.dispose()
        XCTAssertNotNil(result)
        XCTAssertNil(result!)
    }
}
