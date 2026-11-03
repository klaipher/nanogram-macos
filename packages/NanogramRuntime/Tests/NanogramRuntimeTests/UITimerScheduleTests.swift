import XCTest
@testable import NanogramRuntime

final class SecondTickTests: XCTestCase {
    func testTicksLandJustAfterTheNextWholeSecond() {
        XCTAssertEqual(SecondTick.delayToNextSecond(now: 1000.0), 1.0 + SecondTick.margin, accuracy: 0.0001)
        XCTAssertEqual(SecondTick.delayToNextSecond(now: 1000.25), 0.75 + SecondTick.margin, accuracy: 0.0001)
        XCTAssertEqual(SecondTick.delayToNextSecond(now: 1000.999), 0.001 + SecondTick.margin, accuracy: 0.0001)
    }

    func testThirtySecondsOfCountdownTakeAboutThirtyTicksNotOneHundredFifty() {
        var now = 5000.37
        var ticks = 0
        while now + SecondTick.delayToNextSecond(now: now) <= 5030.37 {
            now += SecondTick.delayToNextSecond(now: now)
            ticks += 1
        }
        XCTAssertEqual(ticks, 30)
    }
}

final class AutoNightBoundaryScheduleTests: XCTestCase {
    private func isDark(_ t: Int32, from: Int32, to: Int32) -> Bool {
        return to > from && t >= from && t < to || to < from && (t >= from || t < to)
    }

    func testTheNextCheckNeverSkipsAScheduledSwitch() {
        for (fromHour, toHour) in [(22, 7), (8, 20), (0, 6), (23, 0)] as [(Int32, Int32)] {
            let from = fromHour * 3600
            let to = toHour * 3600
            var t: Int32 = 0
            while t < 86400 {
                let delay = AutoNightBoundarySchedule.nextCheck(secondsOfDay: t, boundaries: [from, to])
                XCTAssertGreaterThanOrEqual(delay, 1)
                XCTAssertLessThanOrEqual(delay, AutoNightBoundarySchedule.maximumInterval)
                let fire = t + Int32(delay)
                var s = t
                while s < fire - 1 {
                    XCTAssertEqual(isDark(s % 86400, from: from, to: to), isDark(t, from: from, to: to), "from \(fromHour) to \(toHour): switch between \(t) and \(fire)")
                    s += 7
                }
                t += 617
            }
        }
    }

    func testASwitchIsCaughtWithinASecondInsteadOfAMinute() {
        let delay = AutoNightBoundarySchedule.nextCheck(secondsOfDay: 22 * 3600 - 30, boundaries: [22 * 3600, 7 * 3600])
        XCTAssertEqual(delay, 31)
        XCTAssertEqual(AutoNightBoundarySchedule.nextCheck(secondsOfDay: 22 * 3600, boundaries: [22 * 3600, 7 * 3600]), AutoNightBoundarySchedule.maximumInterval)
    }

    func testWithoutBoundariesItChecksAtTheMaximumInterval() {
        XCTAssertEqual(AutoNightBoundarySchedule.nextCheck(secondsOfDay: 100, boundaries: []), AutoNightBoundarySchedule.maximumInterval)
    }
}
