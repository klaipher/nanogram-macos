import XCTest
import AppKit
@testable import TGUIKit

private final class ThreadRecordingDisplayLinkSource: SharedDisplayLinkSource {
    var onFrame: ((Double, Double) -> Void)?
    let maximumFramesPerSecond: Int = 120
    private(set) var offMainAccesses = 0
    var onPause: (() -> Void)?

    var isPaused: Bool = true {
        didSet {
            self.record()
            if self.isPaused && !oldValue {
                self.onPause?()
            }
        }
    }

    private func record() {
        if !Thread.isMainThread {
            self.offMainAccesses += 1
        }
    }

    func setScreen(_ screen: NSScreen?) {
        self.record()
    }

    func apply(_ plan: DisplayLinkRatePlan) {
        self.record()
    }
}

final class DisplayLinkThreadingTests: XCTestCase {
    func testInvalidateFromABackgroundQueueUpdatesTheDriverOnMain() {
        let source = ThreadRecordingDisplayLinkSource()
        let driver = SharedDisplayLinkDriver(makeSource: { source })
        let link = driver.add(framesPerSecond: .fps(30), { _ in })
        XCTAssertFalse(source.isPaused)
        XCTAssertEqual(source.offMainAccesses, 0)

        let paused = self.expectation(description: "source paused after the last link went away")
        source.onPause = {
            paused.fulfill()
        }
        let invalidated = self.expectation(description: "invalidate returned on the background queue")
        DispatchQueue.global(qos: .userInitiated).async {
            link.invalidate()
            invalidated.fulfill()
        }
        self.wait(for: [invalidated, paused], timeout: 5.0)

        XCTAssertTrue(source.isPaused)
        XCTAssertEqual(source.offMainAccesses, 0, "the driver touched its display-link source off the main thread")
        withExtendedLifetime(link) {}
    }

    func testBackgroundInvalidateStopsDeliveryBeforeTheMainHop() {
        let source = ThreadRecordingDisplayLinkSource()
        let driver = SharedDisplayLinkDriver(makeSource: { source })
        var ticks = 0
        let link = driver.add(framesPerSecond: .max, { _ in ticks += 1 })
        let invalidated = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            link.invalidate()
            invalidated.signal()
        }
        invalidated.wait()
        source.onFrame?(1000.0, 1000.0 + 1.0 / 120.0)
        XCTAssertEqual(ticks, 0)
        withExtendedLifetime(link) {}
    }
}
