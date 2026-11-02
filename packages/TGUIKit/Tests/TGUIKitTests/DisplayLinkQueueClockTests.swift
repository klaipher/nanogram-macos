import XCTest
import AppKit
import SwiftSignalKit
@testable import TGUIKit

final class DisplayLinkQueueClockTests: XCTestCase {
    private func drain(_ queue: Queue) {
        let done = expectation(description: "drain")
        queue.async {
            DispatchQueue.main.async {
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)
    }

    func testFrameDurationMapsToTheContentRate() {
        XCTAssertEqual(DisplayLinkQueueClock.framesPerSecond(forFrameDuration: 1.0 / 30.0), .fps(30))
        XCTAssertEqual(DisplayLinkQueueClock.framesPerSecond(forFrameDuration: 1.0 / 24.0), .fps(24))
        XCTAssertEqual(DisplayLinkQueueClock.framesPerSecond(forFrameDuration: 0.04), .fps(25))
        XCTAssertEqual(DisplayLinkQueueClock.framesPerSecond(forFrameDuration: 0), .fps(60))
    }

    func testMixedLottieRatesShareOneVsyncTick() {
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 120)
        let driver = SharedDisplayLinkDriver(makeSource: { source })
        let queue = Queue(name: "lottie-test")
        let counts = Atomic<[Int]>(value: [0, 0, 0])
        let clocks = [30, 60, 25].enumerated().map { index, fps in
            DisplayLinkQueueClock(framesPerSecond: .fps(fps), queue: queue, driver: { driver }, tick: {
                _ = counts.modify { value in
                    var value = value
                    value[index] += 1
                    return value
                }
            })
        }
        for clock in clocks {
            clock.start()
        }
        XCTAssertEqual(source.plan?.preferred, 60)
        var callbacks = 0
        for _ in 0 ..< 120 {
            callbacks += source.run(seconds: 1.0 / 60.0)
            self.drain(queue)
        }
        let ticks = counts.with { $0 }
        XCTAssertEqual(callbacks, 120)
        XCTAssertEqual(driver.deliveredEvents, 120)
        XCTAssertEqual(ticks[0], 60)
        XCTAssertEqual(ticks[1], 120)
        XCTAssertEqual(Double(ticks[2]), 50, accuracy: 1)
        for clock in clocks {
            clock.stop()
        }
        XCTAssertTrue(source.isPaused)
    }

    func testBusyQueueDoesNotPileUpTicks() {
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 60)
        let driver = SharedDisplayLinkDriver(makeSource: { source })
        let queue = Queue(name: "lottie-busy")
        let ticks = Atomic<Int>(value: 0)
        let clock = DisplayLinkQueueClock(framesPerSecond: .fps(60), queue: queue, driver: { driver }, tick: {
            _ = ticks.modify { $0 + 1 }
        })
        clock.start()
        let gate = DispatchSemaphore(value: 0)
        queue.async {
            gate.wait()
        }
        XCTAssertEqual(source.run(seconds: 0.5), 30)
        gate.signal()
        self.drain(queue)
        XCTAssertEqual(ticks.with { $0 }, 1)
        clock.stop()
    }

    func testMainQueueClockTicksInline() {
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 120)
        let driver = SharedDisplayLinkDriver(makeSource: { source })
        var ticks = 0
        let clock = DisplayLinkQueueClock(framesPerSecond: .fps(30), queue: .mainQueue(), driver: { driver }, tick: {
            ticks += 1
        })
        clock.start()
        XCTAssertEqual(source.run(seconds: 1), 30)
        XCTAssertEqual(ticks, 30)
        clock.stop()
        XCTAssertEqual(source.run(seconds: 1), 0)
        XCTAssertEqual(ticks, 30)
    }

    func testStoppedClockDropsAPendingTick() {
        let source = FakeDisplayLinkSource(maximumFramesPerSecond: 60)
        let driver = SharedDisplayLinkDriver(makeSource: { source })
        let queue = Queue(name: "lottie-stop")
        let ticks = Atomic<Int>(value: 0)
        let clock = DisplayLinkQueueClock(framesPerSecond: .fps(60), queue: queue, driver: { driver }, tick: {
            _ = ticks.modify { $0 + 1 }
        })
        clock.start()
        let gate = DispatchSemaphore(value: 0)
        queue.async {
            gate.wait()
        }
        _ = source.run(seconds: 1.0 / 60.0)
        clock.stop()
        gate.signal()
        self.drain(queue)
        XCTAssertEqual(ticks.with { $0 }, 0)
    }
}

final class LottieClockWakeupTests: XCTestCase {
    func testDispatchTimersForMixedRates() throws {
        let queue = Queue(name: "lottie-timers")
        let ticks = Atomic<Int>(value: 0)
        let timers = [30.0, 60.0, 25.0].map { fps in
            SwiftSignalKit.Timer(timeout: 1.0 / fps, repeat: true, completion: {
                _ = ticks.modify { $0 + 1 }
                DispatchQueue.main.async {}
            }, queue: queue)
        }
        let before = processWakeups()
        for timer in timers {
            timer.start()
        }
        let done = expectation(description: "done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            done.fulfill()
        }
        wait(for: [done], timeout: 4)
        for timer in timers {
            timer.invalidate()
        }
        let wakeups = Double(processWakeups() - before) / 2.0
        print("LottieClock timers 30+60+25 Hz: ticks/s \(ticks.with { $0 } / 2), process wake-ups/s \(Int(wakeups))")
        XCTAssertGreaterThan(Double(ticks.with { $0 }) / 2.0, 100)
    }

    func testDisplayLinkClocksForMixedRates() throws {
        try skipWhenDisplayLinksCannotTick()
        TGUIKitTestBootstrap.install()
        let queue = Queue(name: "lottie-clocks")
        let ticks = Atomic<Int>(value: 0)
        let clocks = [30.0, 60.0, 25.0].map { fps in
            DisplayLinkQueueClock(frameDuration: 1.0 / fps, queue: queue, tick: {
                _ = ticks.modify { $0 + 1 }
                DispatchQueue.main.async {}
            })
        }
        let before = processWakeups()
        let deliveries = SharedDisplayLinkDriver.shared.deliveredEvents
        for clock in clocks {
            clock.start()
        }
        let done = expectation(description: "done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            done.fulfill()
        }
        wait(for: [done], timeout: 4)
        for clock in clocks {
            clock.stop()
        }
        let wakeups = Double(processWakeups() - before) / 2.0
        let main = Double(SharedDisplayLinkDriver.shared.deliveredEvents - deliveries) / 2.0
        print("LottieClock display link 30+60+25 Hz: ticks/s \(ticks.with { $0 } / 2), main deliveries/s \(Int(main)), process wake-ups/s \(Int(wakeups))")
        XCTAssertEqual(main, 60, accuracy: 6)
        XCTAssertGreaterThan(Double(ticks.with { $0 }) / 2.0, 100)
    }
}
