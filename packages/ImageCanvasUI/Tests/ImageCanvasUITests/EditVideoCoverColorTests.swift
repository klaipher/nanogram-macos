import XCTest
import AVFoundation
import CoreImage
@testable import ImageCanvasUI

final class EditVideoCoverColorTests: XCTestCase {
    private func writeSolidClip(red: UInt8, green: UInt8, blue: UInt8) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let side = 128
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
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
            CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
            guard let buffer = buffer else {
                XCTFail("no buffer")
                break
            }
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0 ..< side {
                for x in 0 ..< side {
                    let pixel = base + y * stride + x * 4
                    pixel[0] = blue
                    pixel[1] = green
                    pixel[2] = red
                    pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        let done = expectation(description: "written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func centerPixel(_ image: CGImage) -> (Int, Int, Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    func testEditedVideoCoverIsAnSRGBImage() throws {
        let url = try writeSolidClip(red: 200, green: 60, blue: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        let spec = EditVideoRenderSpec(url: url, trimStart: 0, trimEnd: 0.3, isMuted: true, tools: [.exposure: 10])
        let cover = try XCTUnwrap(EditVideoExport.frame(spec, maxSide: 800))
        XCTAssertEqual(cover.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testEditedVideoCoverWithoutAdjustmentsKeepsTheSourceColour() throws {
        let url = try writeSolidClip(red: 200, green: 60, blue: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        let spec = EditVideoRenderSpec(url: url, trimStart: 0, trimEnd: 0.3, isMuted: true, orientation: EditVideoOrientation(degrees: 90, mirrored: false))
        let cover = try XCTUnwrap(EditVideoExport.frame(spec, maxSide: 800))
        XCTAssertEqual(cover.colorSpace?.name, CGColorSpace.sRGB)

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let reference = try generator.copyCGImage(at: .zero, actualTime: nil)
        let expected = centerPixel(reference)
        let actual = centerPixel(cover)
        XCTAssertLessThanOrEqual(abs(expected.0 - actual.0), 3, "\(actual) vs \(expected)")
        XCTAssertLessThanOrEqual(abs(expected.1 - actual.1), 3, "\(actual) vs \(expected)")
        XCTAssertLessThanOrEqual(abs(expected.2 - actual.2), 3, "\(actual) vs \(expected)")
    }

    func testStillPreviewsRenderInSRGB() throws {
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let still = try XCTUnwrap(EditVideoRenderer.stillImage(image, from: image.extent))
        XCTAssertEqual(still.colorSpace?.name, CGColorSpace.sRGB)
        let pixel = centerPixel(still)
        XCTAssertEqual(pixel.0, 255)
        XCTAssertLessThanOrEqual(pixel.1, 1)
        XCTAssertLessThanOrEqual(pixel.2, 1)
    }
}
