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

    func testNoPollWhileTheDisplaySleepsOrTheScreenIsLocked() {
        XCTAssertNil(PresenceIdleSchedule.nextCheck(isActive: true, isSleeping: true, isScreenLocked: false, idleTime: 45))
        XCTAssertNil(PresenceIdleSchedule.nextCheck(isActive: true, isSleeping: false, isScreenLocked: true, idleTime: 45))
        XCTAssertNil(PresenceIdleSchedule.nextCheck(isActive: true, isSleeping: true, isScreenLocked: false, idleTime: 0))
        XCTAssertEqual(PresenceIdleSchedule.nextCheck(isActive: true, isSleeping: false, isScreenLocked: false, idleTime: 45), 5)
    }
}

final class PasslockScheduleTests: XCTestCase {
    func testLocksOnceIdleLongerThanTheTimeout() {
        XCTAssertFalse(PasslockSchedule.shouldLock(timeout: 60, idle: 59, resignedAt: nil, now: 1000))
        XCTAssertFalse(PasslockSchedule.shouldLock(timeout: 60, idle: 60, resignedAt: nil, now: 1000))
        XCTAssertTrue(PasslockSchedule.shouldLock(timeout: 60, idle: 61, resignedAt: nil, now: 1000))
    }

    func testLocksOnceResignedLongerThanTheTimeout() {
        XCTAssertFalse(PasslockSchedule.shouldLock(timeout: 60, idle: 0, resignedAt: 950, now: 1000))
        XCTAssertTrue(PasslockSchedule.shouldLock(timeout: 60, idle: 0, resignedAt: 900, now: 1000))
    }

    func testTheNextCheckIsTheEarliestDeadlineNotATenSecondPoll() {
        XCTAssertEqual(PasslockSchedule.nextCheck(timeout: 300, idle: 0, resignedAt: nil, now: 1000), 301)
        XCTAssertEqual(PasslockSchedule.nextCheck(timeout: 300, idle: 120, resignedAt: nil, now: 1000), 181)
        XCTAssertEqual(PasslockSchedule.nextCheck(timeout: 300, idle: 0, resignedAt: 900, now: 1000), 201)
        XCTAssertEqual(PasslockSchedule.nextCheck(timeout: 300, idle: 299.5, resignedAt: nil, now: 1000), 1.5)
    }

    func testAnIdleTimeThatWasResetByInputRearmsFromTheNewIdleTime() {
        let first = PasslockSchedule.nextCheck(timeout: 60, idle: 0, resignedAt: nil, now: 0)
        XCTAssertFalse(PasslockSchedule.shouldLock(timeout: 60, idle: 10, resignedAt: nil, now: Int32(first)))
        XCTAssertEqual(PasslockSchedule.nextCheck(timeout: 60, idle: 10, resignedAt: nil, now: Int32(first)), 51)
    }
}
