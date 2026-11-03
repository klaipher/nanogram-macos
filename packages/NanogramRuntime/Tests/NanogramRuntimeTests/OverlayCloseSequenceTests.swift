import AppKit
import XCTest
@testable import NanogramRuntime

@MainActor
private final class FakeClock {
    var now: TimeInterval = 100
}

@MainActor
private final class FakeMonitors {
    var installed: [Int] = []
    var removed: [Int] = []
    var handlers: [Int: (NSEvent) -> NSEvent?] = [:]
    private var next = 0

    func install(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        next += 1
        installed.append(next)
        handlers[next] = handler
        return next
    }

    func remove(_ token: Any) {
        if let token = token as? Int {
            removed.append(token)
            handlers[token] = nil
        }
    }

    var active: Int {
        return installed.count - removed.count
    }
}

@MainActor
private final class FakeScheduler {
    var pending: [() -> Void] = []

    func schedule(_ work: @escaping () -> Void) {
        pending.append(work)
    }

    func runOneTurn() {
        let work = pending
        pending.removeAll()
        for item in work {
            item()
        }
    }
}

@MainActor
private func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16 = 53, modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
    return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifierFlags, timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: keyCode)!
}

@MainActor
final class ClosingKeySwallowTests: XCTestCase {
    private func makeSwallow(clock: FakeClock, monitors: FakeMonitors, maxDuration: TimeInterval = 1) -> ClosingKeySwallow {
        return ClosingKeySwallow(maxDuration: maxDuration, now: { clock.now }, installMonitor: { monitors.install($0) }, removeMonitor: { monitors.remove($0) })
    }

    func testIdleSwallowLetsEveryKeyThrough() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        let swallow = makeSwallow(clock: clock, monitors: monitors)
        XCTAssertFalse(swallow.isActive)
        XCTAssertFalse(swallow.shouldSwallow(type: .keyDown, modifierFlags: []))
        XCTAssertEqual(monitors.active, 0)
    }

    func testWhileClosingPlainKeyPressesAreSwallowed() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        let swallow = makeSwallow(clock: clock, monitors: monitors)
        swallow.begin()
        XCTAssertTrue(swallow.isActive)
        XCTAssertEqual(monitors.active, 1)
        XCTAssertTrue(swallow.shouldSwallow(type: .keyDown, modifierFlags: []))
        XCTAssertTrue(swallow.shouldSwallow(type: .keyDown, modifierFlags: NSEvent.ModifierFlags.shift))
        XCTAssertFalse(swallow.shouldSwallow(type: .keyUp, modifierFlags: []))
        XCTAssertFalse(swallow.shouldSwallow(type: .flagsChanged, modifierFlags: []))
    }

    func testCommandShortcutsStillReachTheMenu() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        let swallow = makeSwallow(clock: clock, monitors: monitors)
        swallow.begin()
        XCTAssertFalse(swallow.shouldSwallow(type: .keyDown, modifierFlags: NSEvent.ModifierFlags.command))
    }

    func testInstalledMonitorDropsEscapeDuringTheClose() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        let swallow = makeSwallow(clock: clock, monitors: monitors)
        swallow.begin()
        let handler = monitors.handlers[1]!
        XCTAssertNil(handler(keyEvent(.keyDown)))
        XCTAssertNotNil(handler(keyEvent(.keyUp)))
        XCTAssertNotNil(handler(keyEvent(.keyDown, keyCode: 12, modifierFlags: [.command])))
    }

    func testEndRemovesTheMonitorAndRestoresKeys() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        let swallow = makeSwallow(clock: clock, monitors: monitors)
        swallow.begin()
        swallow.end()
        XCTAssertFalse(swallow.isActive)
        XCTAssertEqual(monitors.active, 0)
        XCTAssertFalse(swallow.shouldSwallow(type: .keyDown, modifierFlags: []))
        swallow.end()
        XCTAssertEqual(monitors.removed, [1])
    }

    func testBeginTwiceKeepsOneMonitor() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        let swallow = makeSwallow(clock: clock, monitors: monitors)
        swallow.begin()
        swallow.begin()
        XCTAssertEqual(monitors.installed, [1])
    }

    func testSwallowingExpiresIfTheCloseNeverFinishes() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        let swallow = makeSwallow(clock: clock, monitors: monitors, maxDuration: 1)
        swallow.begin()
        clock.now += 0.5
        XCTAssertTrue(swallow.shouldSwallow(type: .keyDown, modifierFlags: []))
        clock.now += 0.6
        XCTAssertFalse(swallow.isActive)
        XCTAssertFalse(swallow.shouldSwallow(type: .keyDown, modifierFlags: []))
        XCTAssertNotNil(monitors.handlers[1]!(keyEvent(.keyDown)))
    }

    func testReleasingTheSwallowRemovesItsMonitor() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        var swallow: ClosingKeySwallow? = makeSwallow(clock: clock, monitors: monitors)
        swallow?.begin()
        swallow = nil
        XCTAssertEqual(monitors.active, 0)
    }
}

@MainActor
final class OverlayCloseSequenceTests: XCTestCase {
    private func makeSequence(clock: FakeClock, monitors: FakeMonitors, scheduler: FakeScheduler) -> OverlayCloseSequence {
        let swallow = ClosingKeySwallow(maxDuration: 1, now: { clock.now }, installMonitor: { monitors.install($0) }, removeMonitor: { monitors.remove($0) })
        return OverlayCloseSequence(keySwallow: swallow, schedule: { scheduler.schedule($0) })
    }

    func testKeyIsHandedBackOnlyAfterTheCloseAnimationStarted() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        let scheduler = FakeScheduler()
        let sequence = makeSequence(clock: clock, monitors: monitors, scheduler: scheduler)
        var steps: [String] = []
        sequence.close(startAnimation: { steps.append("animation") }, handOffKey: { steps.append("key") })
        XCTAssertEqual(steps, ["animation"])
        scheduler.runOneTurn()
        XCTAssertEqual(steps, ["animation", "key"])
    }

    func testKeysAreSwallowedFromCloseUntilFinish() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        let scheduler = FakeScheduler()
        let sequence = makeSequence(clock: clock, monitors: monitors, scheduler: scheduler)
        var swallowingDuringAnimation = false
        sequence.close(startAnimation: { swallowingDuringAnimation = sequence.isClosing }, handOffKey: {})
        XCTAssertTrue(swallowingDuringAnimation)
        scheduler.runOneTurn()
        XCTAssertTrue(sequence.isClosing)
        XCTAssertNil(monitors.handlers[1]!(keyEvent(.keyDown)))
        sequence.finish()
        XCTAssertFalse(sequence.isClosing)
        XCTAssertEqual(monitors.active, 0)
    }

    func testFinishingBeforeTheTurnSkipsTheStaleHandoff() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        let scheduler = FakeScheduler()
        let sequence = makeSequence(clock: clock, monitors: monitors, scheduler: scheduler)
        var handedOff = 0
        sequence.close(startAnimation: {}, handOffKey: { handedOff += 1 })
        sequence.finish()
        scheduler.runOneTurn()
        XCTAssertEqual(handedOff, 0)
    }

    func testOnlyTheLatestCloseHandsOff() {
        let clock = FakeClock()
        let monitors = FakeMonitors()
        let scheduler = FakeScheduler()
        let sequence = makeSequence(clock: clock, monitors: monitors, scheduler: scheduler)
        var handoffs: [Int] = []
        sequence.close(startAnimation: {}, handOffKey: { handoffs.append(1) })
        sequence.close(startAnimation: {}, handOffKey: { handoffs.append(2) })
        scheduler.runOneTurn()
        XCTAssertEqual(handoffs, [2])
        XCTAssertEqual(monitors.installed, [1])
    }

    func testDefaultScheduleRunsOnALaterRunLoopTurn() {
        var ran = false
        OverlayCloseSequence.nextRunLoopTurn {
            ran = true
        }
        XCTAssertFalse(ran)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(ran)
    }
}
