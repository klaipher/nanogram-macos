import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
import TGVideoCameraMovie

private func makeSolidBGRA(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8, attributes: [String: Any] = [:]) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
            pixel[0] = blue
            pixel[1] = green
            pixel[2] = red
            pixel[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

private func writeMovie(settings: [String: Any], width: Int, height: Int, color: (UInt8, UInt8, UInt8)) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "round_color_\(UUID().uuidString).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for index in 0 ..< 30 {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let buffer = makeSolidBGRA(width: width, height: height, red: color.0, green: color.1, blue: color.2)
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting {
        done.signal()
    }
    done.wait()
    XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    return url
}

private func readCenterPixel(url: URL) throws -> (Int, Int, Int) {
    let asset = AVURLAsset(url: url)
    let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var last: CVPixelBuffer?
    for _ in 0 ..< 10 {
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
            break
        }
        last = buffer
    }
    reader.cancelReading()
    let buffer = try XCTUnwrap(last)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let pixel = base.advanced(by: (CVPixelBufferGetHeight(buffer) / 2) * CVPixelBufferGetBytesPerRow(buffer) + (CVPixelBufferGetWidth(buffer) / 2) * 4)
    return (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))
}

private func assertRec709(_ extensions: [String: Any]?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(extensions?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String, "matrix", file: file, line: line)
    XCTAssertEqual(extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String, "primaries", file: file, line: line)
    XCTAssertEqual(extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String, kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String, "transfer", file: file, line: line)
}

final class RoundVideoColorTests: XCTestCase {
    private func checkWrittenColour(preset: TGMediaVideoConversionPreset, width: Int, height: Int) throws {
        let settings = TGMediaVideoConversionPresetSettings.videoSettings(for: preset, dimensions: CGSize(width: width, height: height), bitrate: 1000) as! [String: Any]
        let colour = settings[AVVideoColorPropertiesKey] as? [String: String]
        XCTAssertEqual(colour?[AVVideoColorPrimariesKey], AVVideoColorPrimaries_ITU_R_709_2)
        XCTAssertEqual(colour?[AVVideoTransferFunctionKey], AVVideoTransferFunction_ITU_R_709_2)
        XCTAssertEqual(colour?[AVVideoYCbCrMatrixKey], AVVideoYCbCrMatrix_ITU_R_709_2)

        let url = try writeMovie(settings: settings, width: width, height: height, color: (255, 0, 0))
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let track = try XCTUnwrap(AVURLAsset(url: url).tracks(withMediaType: .video).first)
        let description = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
        assertRec709(description.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] })

        let (r, g, b) = try readCenterPixel(url: url)
        XCTAssertEqual(r, 255, accuracy: 4, "\(width)×\(height)")
        XCTAssertEqual(g, 0, accuracy: 4, "\(width)×\(height)")
        XCTAssertEqual(b, 0, accuracy: 4, "\(width)×\(height)")
    }

    func testRoundVideoTrackIsTaggedRec709AndKeepsRed() throws {
        try self.checkWrittenColour(preset: TGMediaVideoConversionPresetVideoMessage, width: 300, height: 300)
        try self.checkWrittenColour(preset: TGMediaVideoConversionPresetVideoMessage, width: 480, height: 480)
    }

    func testCompressedTrackIsTaggedRec709AndKeepsRed() throws {
        try self.checkWrittenColour(preset: TGMediaVideoConversionPresetCompressedLow, width: 640, height: 360)
    }

    func testRendererPoolBuffersCarryRec709Attachments() throws {
        typealias PoolFactory = @convention(c) (AnyClass, Selector, Int32, Int32, FourCharCode, Int32) -> Unmanaged<CVPixelBufferPool>?
        let selector = NSSelectorFromString("createPixelBufferPoolWithWidth:height:pixelFormat:maxBufferCount:")
        let rendererClass: AnyClass = TGVideoCameraGLRenderer.self
        let method = try XCTUnwrap(class_getClassMethod(rendererClass, selector))
        let factory = unsafeBitCast(method_getImplementation(method), to: PoolFactory.self)
        let pool = try XCTUnwrap(factory(rendererClass, selector, 300, 300, kCVPixelFormatType_32BGRA, 3)?.takeRetainedValue())
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        XCTAssertEqual(CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        XCTAssertEqual(CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String, kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        XCTAssertEqual(CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String, kCVImageBufferTransferFunction_ITU_R_709_2 as String)
    }
}

private func avcProfileIndication(_ description: CMFormatDescription) -> UInt8? {
    guard let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any], let avcC = atoms["avcC"] as? Data, avcC.count > 1 else {
        return nil
    }
    return avcC[avcC.startIndex + 1]
}

final class RoundVideoSizeTests: XCTestCase {
    private let sideKey = "videoMessageSide"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: self.sideKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: self.sideKey)
        super.tearDown()
    }

    func testRoundVideoSideFollowsServerDiameter() {
        XCTAssertEqual(TGMediaVideoConversionPresetSettings.videoMessageSide(forDiameter: 384), 384)
        XCTAssertEqual(TGMediaVideoConversionPresetSettings.videoMessageSide(forDiameter: 480), 480)
        XCTAssertEqual(TGMediaVideoConversionPresetSettings.videoMessageSide(forDiameter: 385), 384)
        XCTAssertEqual(TGMediaVideoConversionPresetSettings.videoMessageSide(forDiameter: 0), 384)
        XCTAssertEqual(TGMediaVideoConversionPresetSettings.videoMessageSide(forDiameter: 4096), 640)
    }

    func testExplicitSideOverrideIsHonoured() {
        UserDefaults.standard.set(300, forKey: self.sideKey)
        XCTAssertEqual(TGMediaVideoConversionPresetSettings.videoMessageSide(forDiameter: 384), 300)
    }

    func testRoundVideoIsEncodedAtTheDiameterWithHighProfile() throws {
        let side = TGMediaVideoConversionPresetSettings.videoMessageSide(forDiameter: 384)
        let settings = TGMediaVideoConversionPresetSettings.videoSettings(for: TGMediaVideoConversionPresetVideoMessage, dimensions: CGSize(width: side, height: side), bitrate: 1000) as! [String: Any]
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertEqual(compression?[AVVideoProfileLevelKey] as? String, AVVideoProfileLevelH264HighAutoLevel)
        XCTAssertEqual(compression?[AVVideoH264EntropyModeKey] as? String, AVVideoH264EntropyModeCABAC)

        let url = try writeMovie(settings: settings, width: side, height: side, color: (40, 120, 200))
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let track = try XCTUnwrap(AVURLAsset(url: url).tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize, CGSize(width: 384, height: 384))
        let description = try XCTUnwrap(track.formatDescriptions.first.map { $0 as! CMFormatDescription })
        XCTAssertEqual(avcProfileIndication(description), 100)
    }
}
