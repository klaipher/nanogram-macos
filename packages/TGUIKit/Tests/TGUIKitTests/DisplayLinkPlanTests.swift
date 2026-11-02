import XCTest
import AppKit
@testable import TGUIKit

final class FakeDisplayLinkSource: SharedDisplayLinkSource {
    var onFrame: ((Double, Double) -> Void)?
    var maximumFramesPerSecond: Int
    var isPaused: Bool = true
    private(set) var plans: [DisplayLinkRatePlan] = []
    private(set) var screenChanges = 0
    private var time: Double = 1000

    init(maximumFramesPerSecond: Int) {
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }

    var plan: DisplayLinkRatePlan? {
        return self.plans.last
    }

    func setScreen(_ screen: NSScreen?) {
        self.screenChanges += 1
    }

    func apply(_ plan: DisplayLinkRatePlan) {
        if self.plans.last != plan {
            self.plans.append(plan)
        }
    }

    func run(seconds: Double, skippingEvery skip: Int = 0) -> Int {
        var callbacks = 0
        var index = 0
        let end = self.time + seconds
        while self.time < end - 1e-9 {
            let interval = 1.0 / Double(self.plan?.preferred ?? self.maximumFramesPerSecond)
            self.time += interval
            index += 1
            if self.isPaused || (skip > 0 && index.isMultiple(of: skip)) {
                continue
            }
            callbacks += 1
            self.onFrame?(self.time, self.time + interval)
        }
        return callbacks
    }
}

final class DisplayLinkPlanTests: XCTestCase {
    func testPlanAsksForTheHighestRequestedRate() {
        XCTAssertEqual(DisplayLinkRatePlan.make(requested: [.fps(30)], screenMaximum: 120).preferred, 30)
        XCTAssertEqual(DisplayLinkRatePlan.make(requested: [.fps(25), .fps(30), .fps(60)], screenMaximum: 120).preferred, 60)
        XCTAssertEqual(DisplayLinkRatePlan.make(requested: [.fps(25), .max], screenMaximum: 120).preferred, 120)
        XCTAssertEqual(DisplayLinkRatePlan.make(requested: [.max], screenMaximum: 60).preferred, 60)
        XCTAssertEqual(DisplayLinkRatePlan.make(requested: [.fps(120)], screenMaximum: 60).preferred, 60)
        XCTAssertEqual(DisplayLinkRatePlan.make(requested: [.max], screenMaximum: 120, limit: 60).preferred, 60)
        XCTAssertEqual(DisplayLinkRatePlan.make(requested: [.fps(30)], screenMaximum: 120, limit: 60).preferred, 30)
        let plan = DisplayLinkRatePlan.make(requested: [.fps(30)], screenMaximum: 120)
        XCTAssertEqual(plan.minimum, 30)
        XCTAssertEqual(plan.maximum, 30)
    }

    func testAccumulatorKeepsTheContentRateOnAnyBase() {
        for (base, fps, expected) in [(60, 25, 25), (120, 25, 25), (60, 30, 30), (120, 30, 30), (120, 24, 24), (60, 60, 60), (30, 25, 25), (120, 60, 60)] {
            var accumulator = DisplayLinkFrameAccumulator()
            var ticks = 0
            for _ in 0 ..< base * 4 {
                if accumulator.advance(by: 1.0 / Double(base), secondsPerFrame: 1.0 / Double(fps)) {
                    ticks += 1
                }
            }
            XCTAssertEqual(Double(ticks) / 4.0, Double(expected), accuracy: 0.5, "base \(base) fps \(fps)")
        }
    }

    func testAccumulatorDoesNotBurstAfterAStall() {
        var accumulator = DisplayLinkFrameAccumulator()
        XCTAssertTrue(accumulator.advance(by: 0.25, secondsPerFrame: 1.0 / 30.0))
        XCTAssertFalse(accumulator.advance(by: 1.0 / 120.0, secondsPerFrame: 1.0 / 30.0))
    }

    func testDropCounterCountsMissedFrames() {
        var counter = DisplayLinkDropCounter()
        var time = 0.0
        for frame in 0 ..< 120 {
            time += frame == 60 ? 4.0 / 120.0 : 1.0 / 120.0
            _ = counter.record(timestamp: time, interval: 1.0 / 120.0)
        }
        XCTAssertEqual(counter.frames, 120)
        XCTAssertEqual(counter.droppedFrames, 3)
    }

    private func makeDriver(_ source: FakeDisplayLinkSource) -> SharedDisplayLinkDriver {
        return SharedDisplayLinkDriver(makeSource: { source })
    }

    func testThirtyFramesPerSecondOnProMotionWakesThirtyTimes() {
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 120)
        let driver = self.makeDriver(source)
        var ticks = 0
        let link = driver.add(framesPerSecond: .fps(30), { _ in
            ticks += 1
        })
        let callbacks = source.run(seconds: 2)
        withExtendedLifetime(link) {}
        XCTAssertEqual(source.plan?.preferred, 30)
        XCTAssertEqual(callbacks, 60)
        XCTAssertEqual(driver.deliveredEvents, 60)
        XCTAssertEqual(ticks, 60)
    }

    func testSixtyHertzScreen() {
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 60)
        let driver = self.makeDriver(source)
        var ticks = [0, 0, 0]
        var durations: [CGFloat] = []
        let links = [
            driver.add(framesPerSecond: .fps(25), { _ in ticks[0] += 1 }),
            driver.add(framesPerSecond: .fps(30), { _ in ticks[1] += 1 }),
            driver.add(framesPerSecond: .max, { duration in
                ticks[2] += 1
                durations.append(duration)
            })
        ]
        let callbacks = source.run(seconds: 2)
        withExtendedLifetime(links) {}
        XCTAssertEqual(source.plan?.preferred, 60)
        XCTAssertEqual(callbacks, 120)
        XCTAssertEqual(Double(ticks[0]), 50, accuracy: 1)
        XCTAssertEqual(ticks[1], 60)
        XCTAssertEqual(ticks[2], 120)
        XCTAssertEqual(Double(durations[durations.count / 2]), 1.0 / 60.0, accuracy: 1e-6)
    }

    func testOneHundredTwentyHertzScreen() {
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 120)
        let driver = self.makeDriver(source)
        var ticks = [0, 0]
        var durations: [CGFloat] = []
        let links = [
            driver.add(framesPerSecond: .fps(60), { _ in ticks[0] += 1 }),
            driver.add(framesPerSecond: .max, { duration in
                ticks[1] += 1
                durations.append(duration)
            })
        ]
        let callbacks = source.run(seconds: 2)
        withExtendedLifetime(links) {}
        XCTAssertEqual(source.plan?.preferred, 120)
        XCTAssertEqual(callbacks, 240)
        XCTAssertEqual(ticks[0], 120)
        XCTAssertEqual(ticks[1], 240)
        XCTAssertEqual(Double(durations[durations.count / 2]), 1.0 / 120.0, accuracy: 1e-6)
    }

    func testMaxFrameRateLimitCapsInteractiveLinks() {
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 120)
        let driver = self.makeDriver(source)
        let link = driver.add(framesPerSecond: .max, { _ in })
        XCTAssertEqual(source.plan?.preferred, 120)
        driver.maximumFramesPerSecondLimit = 60
        XCTAssertEqual(source.plan?.preferred, 60)
        driver.maximumFramesPerSecondLimit = nil
        XCTAssertEqual(source.plan?.preferred, 120)
        withExtendedLifetime(link) {}
    }

    func testDisplaySwitchFollowsTheNewScreenRate() {
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 120)
        let driver = self.makeDriver(source)
        var durations: [CGFloat] = []
        let link = driver.add(framesPerSecond: .max, { duration in
            durations.append(duration)
        })
        XCTAssertEqual(source.run(seconds: 1), 120)
        source.maximumFramesPerSecond = 60
        let screenChanges = source.screenChanges
        driver.updateDisplay()
        XCTAssertEqual(source.screenChanges, screenChanges + 1)
        XCTAssertEqual(source.plan?.preferred, 60)
        durations.removeAll()
        XCTAssertEqual(source.run(seconds: 1), 60)
        XCTAssertEqual(durations.count, 60)
        XCTAssertEqual(Double(durations[30]), 1.0 / 60.0, accuracy: 1e-6)
        source.maximumFramesPerSecond = 120
        driver.updateDisplay()
        XCTAssertEqual(source.plan?.preferred, 120)
        withExtendedLifetime(link) {}
    }

    func testPausedLinksPauseTheSourceInsteadOfRecreatingIt() {
        var created = 0
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 120)
        let driver = SharedDisplayLinkDriver(makeSource: {
            created += 1
            return source
        })
        let link = driver.add(framesPerSecond: .fps(30), { _ in })
        XCTAssertFalse(source.isPaused)
        link.isPaused = true
        XCTAssertTrue(source.isPaused)
        XCTAssertEqual(source.run(seconds: 1), 0)
        link.isPaused = false
        XCTAssertFalse(source.isPaused)
        driver.updateForegroundState(false)
        XCTAssertTrue(source.isPaused)
        driver.updateForegroundState(true)
        XCTAssertFalse(source.isPaused)
        XCTAssertEqual(created, 1)
        withExtendedLifetime(link) {}
    }

    func testDriverCountsDroppedFrames() {
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 120)
        let driver = self.makeDriver(source)
        let link = driver.add(framesPerSecond: .max, { _ in })
        _ = source.run(seconds: 1, skippingEvery: 10)
        withExtendedLifetime(link) {}
        XCTAssertEqual(driver.droppedFrames, 11)
        XCTAssertEqual(driver.presentedFrames, 108)
    }

    func testLinksChangedFromACallbackAreSafe() {
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 120)
        let driver = self.makeDriver(source)
        var spawned: [SharedDisplayLinkDriver.Link] = []
        var first: SharedDisplayLinkDriver.Link?
        var ticks = 0
        first = driver.add(framesPerSecond: .max, { _ in
            ticks += 1
            first?.invalidate()
            spawned.append(driver.add(framesPerSecond: .fps(30), { _ in }))
            spawned.first?.invalidate()
        })
        XCTAssertEqual(source.run(seconds: 0.1), 1)
        XCTAssertTrue(source.isPaused)
        XCTAssertEqual(ticks, 1)
        withExtendedLifetime(first) {}
        XCTAssertEqual(source.plan?.preferred, 120)
        spawned.removeAll()
        XCTAssertEqual(source.run(seconds: 0.1), 0)
    }
}
