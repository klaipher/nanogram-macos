import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import TGGifConverter

@available(macOS 13.0, *)
final class TGGifConverterTests: XCTestCase {
    private func makeGif(frames: Int, width: Int, height: Int, delay: Double) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let frameProperties = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary
        for index in 0 ..< frames {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: (index * 4) % width, y: 0, width: 16, height: height / 4))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), frameProperties)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func convert(_ gif: Data, exportPath: String = NSTemporaryDirectory() + "gif-converter-\(UUID().uuidString).mp4") async -> (path: String?, failed: Bool, seconds: Double) {
        let finished = self.expectation(description: "conversion finished")
        var path: String?
        var failed = false
        let start = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .userInitiated).async {
            TGGifConverter.convertGif(toMp4: gif, exportPath: exportPath, completionHandler: { result in
                path = result
                finished.fulfill()
            }, errorHandler: {
                failed = true
                finished.fulfill()
            }, cancelHandler: { false })
        }
        await self.fulfillment(of: [finished], timeout: 20)
        return (path, failed, CFAbsoluteTimeGetCurrent() - start)
    }

    func testThreeHundredFrameGifBecomesAPlayableRedMp4() async throws {
        let gif = try self.makeGif(frames: 300, width: 480, height: 270, delay: 0.04)
        let result = await self.convert(gif)
        print("TGGifConverter: 300 frames converted in \(String(format: "%.3f", result.seconds)) s")
        XCTAssertFalse(result.failed)
        let path = try XCTUnwrap(result.path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 12.0, accuracy: 0.2)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 480, height: 270))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let generated = try await generator.image(at: CMTime(seconds: 6, preferredTimescale: 600))
        let frame = generated.image
        let pixel = try self.pixel(of: frame, x: frame.width - 4, y: frame.height - 4)
        XCTAssertGreaterThan(pixel.red, 200)
        XCTAssertLessThan(pixel.green, 60)
        XCTAssertLessThan(pixel.blue, 60)
    }

    func testAnExportPathThatCannotBeWrittenReportsAnError() async throws {
        let gif = try self.makeGif(frames: 10, width: 64, height: 64, delay: 0.1)
        let result = await self.convert(gif, exportPath: "/nonexistent-\(UUID().uuidString)/out.mp4")
        XCTAssertTrue(result.failed)
        XCTAssertNil(result.path)
    }

    func testCancellingStopsWithoutCallingBack() throws {
        let gif = try self.makeGif(frames: 120, width: 320, height: 240, delay: 0.04)
        let exportPath = NSTemporaryDirectory() + "gif-converter-\(UUID().uuidString).mp4"
        let callback = self.expectation(description: "no callback after cancel")
        callback.isInverted = true
        TGGifConverter.convertGif(toMp4: gif, exportPath: exportPath, completionHandler: { _ in
            callback.fulfill()
        }, errorHandler: {
            callback.fulfill()
        }, cancelHandler: { true })
        self.wait(for: [callback], timeout: 2)
        try? FileManager.default.removeItem(atPath: exportPath)
    }

    private func pixel(of image: CGImage, x: Int, y: Int) throws -> (red: Int, green: Int, blue: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
