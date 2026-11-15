import XCTest
import AppKit
import SwiftSignalKit
@testable import TelegramMedia

final class LottieTintedCacheTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        self.directory = NSTemporaryDirectory() + "trlottie-tinted-\(UUID().uuidString)/"
        TRLotData.directoryOverride = self.directory
    }

    override func tearDown() {
        TRLotData.directoryOverride = nil
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    private func animation(_ colors: [LottieColor]) -> LottieAnimation {
        let key = LottieAnimationEntryKey(key: .bundle("tinted-emoji"), size: CGSize(width: 20, height: 20), backingScale: 2, colors: colors)
        return LottieAnimation(compressed: Data(), key: key, cachePurpose: inlineStickerCachePurpose(changesColorsLive: false), maximumFps: 30, colors: colors)
    }

    func testTintedEmojiKeepAFrameCache() {
        guard case .temporaryLZ4(.effect) = inlineStickerCachePurpose(changesColorsLive: false) else {
            return XCTFail("tinted inline emoji must use the effect frame cache")
        }
        guard case .none = inlineStickerCachePurpose(changesColorsLive: true) else {
            return XCTFail("animations that recolour live stay uncached")
        }
        let tinted = self.animation([LottieColor(keyPath: "", color: NSColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))])
        XCTAssertEqual(tinted.liveTime, ASLiveTime.effect.rawValue)
    }

    func testColourKeyIsFixedWidthARGB() {
        XCTAssertEqual(lottieColorCacheKey(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)), "FFFF0000")
        XCTAssertEqual(lottieColorCacheKey(NSColor(deviceRed: 0, green: 0x0A / 255.0, blue: 0xBC / 255.0, alpha: 0.5)), "80000ABC")
        XCTAssertEqual(lottieColorCacheKey(NSColor(deviceRed: 0x0A / 255.0, green: 0xBC / 255.0, blue: 0, alpha: 1)), "FF0ABC00")
    }

    func testCacheFilesDifferByColourAlpha() {
        let opaque = self.animation([LottieColor(keyPath: "", color: NSColor(deviceRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))])
        let translucent = self.animation([LottieColor(keyPath: "", color: NSColor(deviceRed: 0.2, green: 0.4, blue: 0.9, alpha: 0.5))])
        XCTAssertNotEqual(opaque.cacheKey, translucent.cacheKey)
        XCTAssertNotEqual(TRLotData.dataPath(opaque, bufferSize: opaque.bufferSize), TRLotData.dataPath(translucent, bufferSize: translucent.bufferSize))
    }

    func testTintedFramesAreReadFromTheCacheAfterOneLoop() {
        let tinted = self.animation([LottieColor(keyPath: "", color: NSColor(deviceRed: 0.9, green: 0.1, blue: 0.3, alpha: 1))])
        let bufferSize = tinted.bufferSize
        let supplyment = TRLotFileSupplyment(tinted, bufferSize: bufferSize, queue: Queue())
        supplyment.initialize(fps: 30, startFrame: 0, endFrame: 2)
        let frames = (0 ..< 2).map { index in Data((0 ..< bufferSize).map { UInt8(truncatingIfNeeded: $0 &* (index + 3)) }) }
        for (index, frame) in frames.enumerated() {
            supplyment.addFrame(nil, (frame, Int32(index)))
        }
        supplyment.markFinished()
        _ = supplyment.fps
        XCTAssertTrue(supplyment.isFinished)
        let reopened = TRLotFileSupplyment(tinted, bufferSize: bufferSize, queue: Queue())
        _ = reopened.fps
        XCTAssertTrue(reopened.isFinished)
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(reopened.readFrame(previous: nil, frame: index), frame, "frame \(index)")
        }
    }
}
