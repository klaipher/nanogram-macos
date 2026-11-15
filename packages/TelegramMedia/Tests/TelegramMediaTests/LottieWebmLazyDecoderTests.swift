import XCTest
import AppKit
import SwiftSignalKit
import TelegramMediaPlayer
@testable import TelegramMedia

final class LottieWebmLazyDecoderTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        self.directory = NSTemporaryDirectory() + "trlottie-webm-\(UUID().uuidString)/"
        TRLotData.directoryOverride = self.directory
    }

    override func tearDown() {
        TRLotData.directoryOverride = nil
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    private func makeAnimation(_ name: String) -> LottieAnimation {
        let key = LottieAnimationEntryKey(key: .bundle("webm-\(name)"), size: CGSize(width: 20, height: 20), backingScale: 2)
        return LottieAnimation(compressed: "/nonexistent/\(name).webm".data(using: .utf8)!, key: key, type: .webm, cachePurpose: .temporaryLZ4(.effect))
    }

    private func missingSource() -> SoftwareVideoSource {
        return SoftwareVideoSource(path: "/nonexistent.webm", hintVP9: true, unpremultiplyAlpha: false, reusePixelBuffers: false)
    }

    func testFinishedCacheOpensNoDecoder() {
        let animation = self.makeAnimation("finished")
        let bufferSize = animation.bufferSize
        let writer = TRLotFileSupplyment(animation, bufferSize: bufferSize, queue: Queue())
        writer.initialize(fps: 25, startFrame: 0, endFrame: 2)
        let frames = (0 ..< 2).map { index in Data(repeating: UInt8(40 + index), count: bufferSize) }
        for (index, frame) in frames.enumerated() {
            writer.addFrame(nil, (frame, Int32(index)))
        }
        writer.markFinished()
        _ = writer.fps

        var inits = 0
        let supplyment = TRLotFileSupplyment(animation, bufferSize: bufferSize, queue: Queue())
        let renderer = WebmRenderer(animation: animation, makeDecoder: {
            inits += 1
            return self.missingSource()
        }, fileSupplyment: supplyment)
        XCTAssertEqual(renderer.fps, 25)
        XCTAssertEqual(renderer.endFrame, 2)
        for index in 0 ..< 2 {
            let frame = renderer.render(at: Int32(index), frames: [], previousFrame: nil)
            XCTAssertEqual(frame?.data, frames[index])
            XCTAssertEqual((frame as? RenderedWebmFrame)?.fromCache, true)
        }
        XCTAssertEqual(inits, 0)
    }

    func testCacheMissStillOpensTheDecoderOnce() {
        let animation = self.makeAnimation("miss")
        let bufferSize = animation.bufferSize
        let writer = TRLotFileSupplyment(animation, bufferSize: bufferSize, queue: Queue())
        writer.initialize(fps: 30, startFrame: 0, endFrame: 3)
        writer.addFrame(nil, (Data(repeating: 1, count: bufferSize), 0))
        writer.markFinished()
        _ = writer.fps

        var inits = 0
        let renderer = WebmRenderer(animation: animation, makeDecoder: {
            inits += 1
            return self.missingSource()
        }, fileSupplyment: TRLotFileSupplyment(animation, bufferSize: bufferSize, queue: Queue()))
        XCTAssertNotNil(renderer.render(at: 0, frames: [], previousFrame: nil))
        XCTAssertEqual(inits, 0)
        _ = renderer.render(at: 5, frames: [], previousFrame: nil)
        _ = renderer.render(at: 6, frames: [], previousFrame: nil)
        XCTAssertLessThanOrEqual(inits, 1)
    }

    func testUncachedAnimationOpensTheDecoderUpFront() {
        let animation = self.makeAnimation("uncached")
        var inits = 0
        _ = WebmRenderer(animation: animation, makeDecoder: {
            inits += 1
            return self.missingSource()
        }, fileSupplyment: TRLotFileSupplyment(animation, bufferSize: animation.bufferSize, queue: Queue()))
        XCTAssertEqual(inits, 1)
    }
}
