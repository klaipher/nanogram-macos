import XCTest
import AppKit
import SwiftSignalKit
import Compression
@testable import TelegramMedia

final class LottieFrameCodecTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        self.directory = NSTemporaryDirectory() + "trlottie-codec-\(UUID().uuidString)/"
        TRLotData.directoryOverride = self.directory
    }

    override func tearDown() {
        TRLotData.directoryOverride = nil
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    private func stickerFrame(side: Int, phase: Int) -> Data {
        let bytesPerRow = side * 4
        var data = Data(count: bytesPerRow * side)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let s = CGFloat(side)
            let t = CGFloat(phase) / 30.0
            context.setFillColor(NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8))
            context.setFillColor(NSColor(red: 0.4, green: 0.2, blue: 0.1, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: s * (0.3 + 0.05 * sin(t * 6)), y: s * 0.55, width: s * 0.12, height: s * 0.15))
            context.fillEllipse(in: CGRect(x: s * (0.58 + 0.05 * sin(t * 6)), y: s * 0.55, width: s * 0.12, height: s * 0.15))
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.9).cgColor, NSColor(red: 0.5, green: 0.0, blue: 0.1, alpha: 0.6).cgColor] as CFArray, locations: [0, 1])!
            context.saveGState()
            context.addEllipse(in: CGRect(x: s * 0.3, y: s * (0.2 + 0.05 * cos(t * 4)), width: s * 0.4, height: s * 0.2))
            context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s * 0.2), end: CGPoint(x: 0, y: s * 0.4), options: [])
            context.restoreGState()
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(s * 0.02)
            context.strokeEllipse(in: CGRect(x: s * 0.12, y: s * 0.12, width: s * 0.76, height: s * 0.76))
        }
        return data
    }

    private func measure(_ algorithm: compression_algorithm, frames: [Data]) -> (encodeMs: Double, decodeMs: Double, bytes: Int, roundTrip: Bool) {
        let size = frames[0].count
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: size * 2)
        let decoded = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        let encodeScratch = malloc(compression_encode_scratch_buffer_size(algorithm))
        let decodeScratch = malloc(compression_decode_scratch_buffer_size(algorithm))
        defer {
            destination.deallocate()
            decoded.deallocate()
            free(encodeScratch)
            free(decodeScratch)
        }
        var encoded: [Data] = []
        let encodeStart = CACurrentMediaTime()
        for frame in frames {
            let length = frame.withUnsafeBytes { compression_encode_buffer(destination, size * 2, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), size, encodeScratch, algorithm) }
            encoded.append(Data(bytes: destination, count: length))
        }
        let encodeTime = CACurrentMediaTime() - encodeStart
        var roundTrip = true
        let decodeStart = CACurrentMediaTime()
        for (index, data) in encoded.enumerated() {
            let length = data.withUnsafeBytes { compression_decode_buffer(decoded, size, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, decodeScratch, algorithm) }
            if length != size || memcmp(decoded, (frames[index] as NSData).bytes, size) != 0 {
                roundTrip = false
            }
        }
        let decodeTime = CACurrentMediaTime() - decodeStart
        return (encodeTime / Double(frames.count) * 1000, decodeTime / Double(frames.count) * 1000, encoded.reduce(0) { $0 + $1.count }, roundTrip)
    }

    func testCodecBenchmarkOnStickerFrames() throws {
        guard #available(macOS 11.0, *) else {
            throw XCTSkip("LZBITMAP needs macOS 11")
        }
        for side in [416, 320, 256, 200, 160, 120, 80] {
            let frames = (0 ..< 60).map { self.stickerFrame(side: side, phase: $0) }
            var results: [String: (encodeMs: Double, decodeMs: Double, bytes: Int, roundTrip: Bool)] = [:]
            let codecs: [(String, compression_algorithm)] = [("lzfse", COMPRESSION_LZFSE), ("lz4", COMPRESSION_LZ4), ("lzbitmap", COMPRESSION_LZBITMAP)]
            for (_, algorithm) in codecs {
                _ = self.measure(algorithm, frames: Array(frames.prefix(5)))
            }
            for _ in 0 ..< 5 {
                for (name, algorithm) in codecs {
                    let result = self.measure(algorithm, frames: frames)
                    XCTAssertTrue(result.roundTrip, name)
                    if let current = results[name] {
                        results[name] = (min(current.encodeMs, result.encodeMs), min(current.decodeMs, result.decodeMs), result.bytes, result.roundTrip)
                    } else {
                        results[name] = result
                    }
                }
            }
            for (name, _) in codecs {
                let result = results[name]!
                print(String(format: "LottieFrameCodec %dpx %@: encode %.3f ms/frame, decode %.3f ms/frame, %.1f KB/frame (best of 5)", side, name, result.encodeMs, result.decodeMs, Double(result.bytes) / 1024.0 / Double(frames.count)))
            }
            let lzfse = try XCTUnwrap(results["lzfse"])
            let lz4 = try XCTUnwrap(results["lz4"])
            XCTAssertLessThan(lz4.encodeMs * 4, lzfse.encodeMs, "\(side)px")
            XCTAssertLessThan(lz4.decodeMs, lzfse.decodeMs * 1.25, "\(side)px")
        }
    }

    func testNewCacheFilesUseTheFastCodecAndANewVersion() throws {
        XCTAssertEqual(LottieFrameCodec.current.fileTag, "lz4")
        let key = LottieAnimationEntryKey(key: .bundle("codec-path"), size: CGSize(width: 40, height: 40), backingScale: 2)
        let animation = LottieAnimation(compressed: Data(), key: key, cachePurpose: .temporaryLZ4(.effect))
        let path = TRLotData.dataPath(animation, bufferSize: animation.bufferSize)
        XCTAssertTrue(path.contains("-v71-lz4-"), path)
        XCTAssertFalse(path.contains("lzfse"), path)
    }

    func testStickerFramesRoundTripThroughTheCache() {
        let side = 104
        let key = LottieAnimationEntryKey(key: .bundle("codec-roundtrip-\(UUID().uuidString)"), size: CGSize(width: side / 2, height: side / 2), backingScale: 2)
        let animation = LottieAnimation(compressed: Data(), key: key)
        let bufferSize = animation.bufferSize
        XCTAssertEqual(bufferSize, side * side * 4)
        let supplyment = TRLotFileSupplyment(animation, bufferSize: bufferSize, queue: Queue())
        supplyment.initialize(fps: 30, startFrame: 0, endFrame: 3)
        let frames = (0 ..< 3).map { self.stickerFrame(side: side, phase: $0 * 7) }
        for (index, frame) in frames.enumerated() {
            supplyment.addFrame(nil, (frame, Int32(index)))
        }
        supplyment.markFinished()
        _ = supplyment.fps
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(supplyment.readFrame(previous: nil, frame: index), frame, "frame \(index)")
        }
    }
}
