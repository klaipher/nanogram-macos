import XCTest
@testable import NanogramRuntime

final class AccountWakeupFlagsCacheTests: XCTestCase {
    private let base = AccountWakeupFlags(serviceTaskMaster: true, keepWorkerConnections: false, keepOnlinePresence: true, keepBackgroundDownloads: false)

    func testTenIdenticalUpdatesSetEachPromiseOnce() {
        let cache = AccountWakeupFlagsCache<Int>()
        var sets = 0
        for _ in 0 ..< 10 {
            sets += cache.changes(for: 1, base).count
        }
        XCTAssertEqual(sets, 4)
    }

    func testOnlyChangedFlagsAreReported() {
        let cache = AccountWakeupFlagsCache<Int>()
        _ = cache.changes(for: 1, base)
        var updated = base
        updated.keepOnlinePresence = false
        XCTAssertEqual(cache.changes(for: 1, updated), [.keepOnlinePresence])
        updated.serviceTaskMaster = false
        updated.keepBackgroundDownloads = true
        XCTAssertEqual(cache.changes(for: 1, updated), [.serviceTaskMaster, .keepBackgroundDownloads])
        XCTAssertEqual(cache.changes(for: 2, updated).count, 4)
    }

    func testRemovedAccountsStartOver() {
        let cache = AccountWakeupFlagsCache<Int>()
        _ = cache.changes(for: 1, base)
        cache.keep(only: [])
        XCTAssertEqual(cache.changes(for: 1, base).count, 4)
    }

    func testInvalidateForcesTheNextSet() {
        let cache = AccountWakeupFlagsCache<Int>()
        _ = cache.changes(for: 1, base)
        cache.invalidate(.serviceTaskMaster)
        XCTAssertEqual(cache.changes(for: 1, base), [.serviceTaskMaster])
    }
}

final class SleepStateTests: XCTestCase {
    func testDisplaySleepKeepsTheNetworkUpButMarksPresenceAsSleeping() {
        var state = SleepState()
        state.screensDidSleep()
        XCTAssertTrue(state.isSleeping)
        XCTAssertTrue(state.keepsNetwork)
        state.screensDidWake()
        XCTAssertFalse(state.isSleeping)
        XCTAssertTrue(state.keepsNetwork)
    }

    func testSystemSleepPausesTheNetworkUntilWake() {
        var state = SleepState()
        state.systemWillSleep()
        XCTAssertTrue(state.isSleeping)
        XCTAssertFalse(state.keepsNetwork)
        state.screensDidWake()
        XCTAssertFalse(state.keepsNetwork)
        state.systemDidWake()
        XCTAssertTrue(state.keepsNetwork)
        XCTAssertFalse(state.isSleeping)
    }
}

final class PresenceIdleScheduleTests: XCTestCase {
    func testInactiveAppNeedsNoCheck() {
        XCTAssertNil(PresenceIdleSchedule.nextCheck(isActive: false, idleTime: 0))
    }

    func testActiveAppChecksWhenTheIdleThresholdWouldBeReached() {
        XCTAssertEqual(PresenceIdleSchedule.nextCheck(isActive: true, idleTime: 0), 30)
        XCTAssertEqual(PresenceIdleSchedule.nextCheck(isActive: true, idleTime: 12), 18)
        XCTAssertEqual(PresenceIdleSchedule.nextCheck(isActive: true, idleTime: 29.9), 1)
    }

    func testIdleActiveAppPollsForReturn() {
        XCTAssertEqual(PresenceIdleSchedule.nextCheck(isActive: true, idleTime: 45), 5)
    }
}
