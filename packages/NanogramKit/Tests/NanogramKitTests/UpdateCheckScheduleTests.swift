import XCTest
@testable import NanogramKit

final class UpdateCheckScheduleTests: XCTestCase {
    private final class StubUpdater {
        var lastCheck: Date?
        var checks = 0

        func backgroundCheck(now: Date) {
            guard UpdateCheckSchedule.isBackgroundCheckDue(lastCheck: lastCheck, now: now) else {
                return
            }
            checks += 1
            lastCheck = now
        }
    }

    func test_intervalIsOneDay() {
        XCTAssertEqual(UpdateCheckSchedule.interval, 24 * 60 * 60)
    }

    func test_firstCheckIsDue() {
        XCTAssertTrue(UpdateCheckSchedule.isBackgroundCheckDue(lastCheck: nil, now: Date()))
    }

    func test_networkSettingsEmissionsWithinADay_checkOnce() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let updater = StubUpdater()
        for offset in [0.0, 5, 60, 3600, 7200] {
            updater.backgroundCheck(now: start.addingTimeInterval(offset))
        }
        XCTAssertEqual(updater.checks, 1)
        updater.backgroundCheck(now: start.addingTimeInterval(UpdateCheckSchedule.interval))
        XCTAssertEqual(updater.checks, 2)
    }

    func test_clockMovedBack_checks() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(UpdateCheckSchedule.isBackgroundCheckDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }
}
