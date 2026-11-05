import Foundation
import XCTest
import SwiftSignalKit
import TelegramCore
@testable import TelegramUtils


private final class FakeEnvironment: PeerPresenceStatusManagerEnvironment {
    private struct PendingTimer {
        let id: Int
        let deadline: Double
        let f: () -> Void
    }

    var currentTimestamp: Double
    var isApplicationInBackground: Bool = false {
        didSet {
            if oldValue != self.isApplicationInBackground {
                for f in self.listeners.copyItems() {
                    f()
                }
            }
        }
    }

    private var nextId = 0
    private var timers: [PendingTimer] = []
    private let listeners = Bag<() -> Void>()
    private(set) var scheduledTimerCount = 0

    init(timestamp: Double) {
        self.currentTimestamp = timestamp
    }

    var pendingTimerCount: Int {
        return self.timers.count
    }

    var nextDeadline: Double? {
        return self.timers.map(\.deadline).min()
    }

    func scheduleTimer(timeout: Double, _ f: @escaping () -> Void) -> Disposable {
        self.nextId += 1
        let id = self.nextId
        self.scheduledTimerCount += 1
        self.timers.append(PendingTimer(id: id, deadline: self.currentTimestamp + timeout, f: f))
        return ActionDisposable { [weak self] in
            self?.timers.removeAll(where: { $0.id == id })
        }
    }

    func addApplicationStateListener(_ f: @escaping () -> Void) -> Disposable {
        let index = self.listeners.add(f)
        return ActionDisposable { [weak self] in
            self?.listeners.remove(index)
        }
    }

    @discardableResult
    func advance(to timestamp: Double, maxFires: Int = 10_000) -> Bool {
        var fires = 0
        while let index = self.timers.indices.min(by: { self.timers[$0].deadline < self.timers[$1].deadline }), self.timers[index].deadline <= timestamp {
            let timer = self.timers.remove(at: index)
            self.currentTimestamp = max(self.currentTimestamp, timer.deadline)
            timer.f()
            fires += 1
            if fires >= maxFires {
                return false
            }
        }
        self.currentTimestamp = max(self.currentTimestamp, timestamp)
        return true
    }
}

private func present(_ until: Int32, lastActivity: Int32 = 0) -> TelegramUserPresence {
    return TelegramUserPresence(status: .present(until: until), lastActivity: lastActivity)
}

private func isOnline(_ presence: TelegramUserPresence, at timestamp: Double, timeDifference: Int32 = 0) -> Bool {
    if case let .present(until) = presence.status {
        return Int64(until) - Int64(timeDifference) > Int64(timestamp)
    }
    return false
}

private func statusLabel(_ presence: TelegramUserPresence, at timestamp: Double) -> String {
    guard case let .present(until) = presence.status else {
        return "other"
    }
    let now = Int32(timestamp)
    if until > now {
        return "online"
    }
    let difference = now - until
    if difference < 59 {
        return "just now"
    } else if difference < 60 * 60 {
        return "\(max(difference / 60, 1)) min"
    } else {
        return "hours"
    }
}

final class PeerPresenceStatusManagerTests: XCTestCase {
    private func makeRow(environment: FakeEnvironment, presence: TelegramUserPresence, mode: PeerPresenceStatusRefreshMode, timeDifference: Int32 = 0, layoutCost: Double = 0.002) -> (manager: PeerPresenceStatusManager, updates: () -> Int, shownOnline: () -> Bool) {
        var updateCount = 0
        var shownOnline = isOnline(presence, at: environment.currentTimestamp, timeDifference: timeDifference)
        var managerRef: PeerPresenceStatusManager?
        let manager = PeerPresenceStatusManager(mode: mode, environment: environment, update: {
            updateCount += 1
            environment.currentTimestamp += layoutCost
            shownOnline = isOnline(presence, at: environment.currentTimestamp, timeDifference: timeDifference)
            managerRef?.reset(presence: presence, timeDifference: timeDifference)
        })
        managerRef = manager
        manager.reset(presence: presence, timeDifference: timeDifference)
        return (manager, { updateCount }, { shownOnline })
    }

    func testOnlineExpiryRefreshesOnceWithoutSpinning() {
        for fraction in [0.0, 0.01, 0.3, 0.5, 0.97, 0.999] {
            let start = 1_000_000.0 + fraction
            let environment = FakeEnvironment(timestamp: start)
            let presence = present(1_000_005)
            let row = self.makeRow(environment: environment, presence: presence, mode: .onlineState)
            XCTAssertTrue(row.shownOnline())

            let finished = environment.advance(to: start + 3600.0)
            XCTAssertTrue(finished, "refresh loop did not settle (fraction \(fraction))")
            XCTAssertEqual(row.updates(), 1, "fraction \(fraction)")
            XCTAssertFalse(row.shownOnline())
            XCTAssertEqual(environment.pendingTimerCount, 0)
            withExtendedLifetime(row.manager) {}
        }
    }

    func testStatusTextExpiryDoesNotSpinInTheExpirySecond() {
        for fraction in [0.0, 0.01, 0.5, 0.999] {
            let until: Int32 = 1_000_005
            let environment = FakeEnvironment(timestamp: Double(until) - 1.0 + fraction)
            let presence = present(until)
            let row = self.makeRow(environment: environment, presence: presence, mode: .statusText)
            XCTAssertTrue(environment.advance(to: Double(until) + 2.0, maxFires: 20), "spun at fraction \(fraction)")
            XCTAssertLessThanOrEqual(row.updates(), 2, "fraction \(fraction)")
            withExtendedLifetime(row.manager) {}
        }
    }

    func testOnlineDotDisappearsAsSoonAsStatusExpires() {
        let environment = FakeEnvironment(timestamp: 1_000_000.4)
        let presence = present(1_000_010)
        let row = self.makeRow(environment: environment, presence: presence, mode: .onlineState, layoutCost: 0.0)

        environment.advance(to: 1_000_009.99)
        XCTAssertTrue(row.shownOnline())
        XCTAssertEqual(row.updates(), 0)
        environment.advance(to: 1_000_010.0)
        XCTAssertFalse(row.shownOnline())
        XCTAssertEqual(row.updates(), 1)
        withExtendedLifetime(row.manager) {}
    }

    func testTimeDifferenceShiftsTheDeadline() {
        let environment = FakeEnvironment(timestamp: 1_000_000.4)
        let presence = present(1_000_110)
        let row = self.makeRow(environment: environment, presence: presence, mode: .onlineState, timeDifference: 100, layoutCost: 0.0)
        XCTAssertTrue(row.shownOnline())
        XCTAssertEqual(environment.nextDeadline ?? 0.0, 1_000_010.0, accuracy: 0.001)
        environment.advance(to: 1_000_020.0)
        XCTAssertEqual(row.updates(), 1)
        XCTAssertFalse(row.shownOnline())
        withExtendedLifetime(row.manager) {}
    }

    func testOnlineStateModeDoesNotTickWhileOffline() {
        let environment = FakeEnvironment(timestamp: 1_000_000.0)
        let presence = present(1_000_000 - 70)
        let row = self.makeRow(environment: environment, presence: presence, mode: .onlineState)
        XCTAssertEqual(environment.pendingTimerCount, 0)
        environment.advance(to: 1_000_000.0 + 3600.0)
        XCTAssertEqual(row.updates(), 0)
        withExtendedLifetime(row.manager) {}
    }

    func testStatusTextRefreshesOncePerLabelChangeAndNeverLate() {
        let until: Int32 = 1_000_000
        let presence = present(until)
        let environment = FakeEnvironment(timestamp: Double(until) - 2.5)
        var shown = statusLabel(presence, at: environment.currentTimestamp)
        var updates = 0
        var managerRef: PeerPresenceStatusManager?
        let manager = PeerPresenceStatusManager(mode: .statusText, environment: environment, update: {
            updates += 1
            shown = statusLabel(presence, at: environment.currentTimestamp)
            managerRef?.reset(presence: presence, timeDifference: 0)
        })
        managerRef = manager
        manager.reset(presence: presence, timeDifference: 0)

        var maxStaleness = 0.0
        var labelChanges = 0
        var previousTrue = shown
        var t = environment.currentTimestamp
        let end = Double(until) + 2.0 * 3600.0
        let step = 0.05
        var staleSince: Double?
        while t < end {
            t += step
            if !environment.advance(to: t, maxFires: 100) {
                XCTFail("refresh loop did not settle at \(t)")
                break
            }
            let trueLabel = statusLabel(presence, at: t)
            if trueLabel != previousTrue {
                labelChanges += 1
                previousTrue = trueLabel
            }
            if shown != trueLabel {
                if staleSince == nil {
                    staleSince = t
                }
                maxStaleness = max(maxStaleness, t - staleSince!)
            } else {
                staleSince = nil
            }
        }
        XCTAssertLessThanOrEqual(maxStaleness, 0.15, "label lagged by \(maxStaleness) s")
        XCTAssertEqual(labelChanges, 61)
        XCTAssertLessThanOrEqual(updates, labelChanges + 1, "\(updates) wakeups for \(labelChanges) label changes")
        withExtendedLifetime(manager) {}
    }

    func testRecentlyIsOnlineForThirtySecondsOfActivity() {
        let environment = FakeEnvironment(timestamp: 1_000_000.5)
        let presence = TelegramUserPresence(status: .recently(isHidden: false), lastActivity: 1_000_000 - 10)
        var updates = 0
        let manager = PeerPresenceStatusManager(mode: .onlineState, environment: environment, update: {
            updates += 1
        })
        manager.reset(presence: presence, timeDifference: 0)
        XCTAssertEqual(environment.nextDeadline ?? 0.0, 1_000_021.0, accuracy: 0.001)
        environment.advance(to: 1_000_100.0)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(environment.pendingTimerCount, 0)
    }

    func testExtremeTimestampsDoNotOverflow() {
        let now = 1_000_000.25
        let forever = present(Int32.max)
        for mode in [PeerPresenceStatusRefreshMode.statusText, .onlineState] {
            XCTAssertEqual(peerPresenceStatusRefreshTimeout(forever, timeDifference: 0, relativeTo: now, mode: mode), Double.infinity)
            XCTAssertEqual(peerPresenceStatusRefreshTimeout(forever, timeDifference: -100, relativeTo: now, mode: mode), Double.infinity)
        }
        let longAgo = present(Int32.min)
        XCTAssertEqual(peerPresenceStatusRefreshTimeout(longAgo, timeDifference: Int32.max, relativeTo: now, mode: .statusText), Double.infinity)
        let recently = TelegramUserPresence(status: .recently(isHidden: false), lastActivity: Int32.max)
        XCTAssertGreaterThan(peerPresenceStatusRefreshTimeout(recently, timeDifference: Int32.min, relativeTo: now, mode: .statusText), 0.0)
        let manager = PeerPresenceStatusManager(update: {})
        manager.reset(presence: forever, timeDifference: 0)
    }

    func testTimeoutIsSaneForAnyInput() {
        let seconds: [Int32] = [Int32.min, Int32.min + 1, -31, -1, 0, 1, 30, 31, 3_600, 1_000_000_000, Int32.max - 31, Int32.max - 30, Int32.max - 1, Int32.max]
        var statuses: [UserPresenceStatus] = [.recently(isHidden: false), .recently(isHidden: true), .lastWeek(isHidden: false), .lastMonth(isHidden: false), .none]
        statuses.append(contentsOf: seconds.map { .present(until: $0) })
        var clocks: [Double] = [0.0, -1.0, 0.5, 1_000_000_000.25, Double(Int32.max), Double(Int32.max) + 0.5, Double(Int32.min), Double(Int32.min) - 1.0, 1e15, -1e15, 1e18, -1e18, 9.3e18, -9.3e18, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, .infinity, -.infinity, .nan]
        clocks.append(contentsOf: seconds.map { Double($0) + 0.999 })
        for status in statuses {
            for lastActivity in seconds {
                let presence = TelegramUserPresence(status: status, lastActivity: lastActivity)
                for timeDifference in [Int32.min, -1, 0, 1, 3_600, Int32.max] {
                    for clock in clocks {
                        for mode in [PeerPresenceStatusRefreshMode.statusText, .onlineState] {
                            let timeout = peerPresenceStatusRefreshTimeout(presence, timeDifference: timeDifference, relativeTo: clock, mode: mode)
                            XCTAssertFalse(timeout.isNaN, "\(status) \(lastActivity) \(clock)")
                            XCTAssertGreaterThanOrEqual(timeout, 0.05, "\(status) \(lastActivity) \(clock)")
                        }
                    }
                }
            }
        }
    }

    func testNonFiniteClockSchedulesNothing() {
        let presence = present(1_000)
        for clock in [Double.nan, .infinity, -.infinity] {
            let environment = FakeEnvironment(timestamp: clock)
            let manager = PeerPresenceStatusManager(mode: .statusText, environment: environment, update: {})
            manager.reset(presence: presence, timeDifference: 0)
            XCTAssertEqual(environment.pendingTimerCount, 0)
        }
    }

    func testNoTimersOrUpdatesInBackgroundAndSingleCatchUpOnForeground() {
        let environment = FakeEnvironment(timestamp: 1_000_000.0)
        let presence = present(1_000_005)
        let row = self.makeRow(environment: environment, presence: presence, mode: .onlineState)
        XCTAssertEqual(environment.pendingTimerCount, 1)

        environment.advance(to: 1_000_001.0)
        environment.isApplicationInBackground = true
        XCTAssertEqual(environment.pendingTimerCount, 0)
        environment.advance(to: 1_000_600.0)
        XCTAssertEqual(row.updates(), 0)
        XCTAssertTrue(row.shownOnline())

        environment.isApplicationInBackground = false
        XCTAssertEqual(row.updates(), 1)
        XCTAssertFalse(row.shownOnline())
        XCTAssertEqual(environment.pendingTimerCount, 0)
        withExtendedLifetime(row.manager) {}
    }

    func testForegroundBeforeDeadlineReschedulesRemainingTime() {
        let environment = FakeEnvironment(timestamp: 1_000_000.25)
        let presence = present(1_000_100)
        let row = self.makeRow(environment: environment, presence: presence, mode: .onlineState, layoutCost: 0.0)

        environment.isApplicationInBackground = true
        environment.advance(to: 1_000_050.0)
        environment.isApplicationInBackground = false
        XCTAssertEqual(row.updates(), 0)
        XCTAssertEqual(environment.pendingTimerCount, 1)
        XCTAssertEqual(environment.nextDeadline ?? 0.0, 1_000_100.0, accuracy: 0.001)

        environment.advance(to: 1_000_200.0)
        XCTAssertEqual(row.updates(), 1)
        XCTAssertFalse(row.shownOnline())
        withExtendedLifetime(row.manager) {}
    }

    func testResetToFinalStateCancelsPendingTimer() {
        let environment = FakeEnvironment(timestamp: 1_000_000.0)
        var updates = 0
        let manager = PeerPresenceStatusManager(mode: .onlineState, environment: environment, update: {
            updates += 1
        })
        manager.reset(presence: present(1_000_100), timeDifference: 0)
        XCTAssertEqual(environment.pendingTimerCount, 1)
        manager.reset(presence: TelegramUserPresence(status: .lastWeek(isHidden: false), lastActivity: 0), timeDifference: 0)
        XCTAssertEqual(environment.pendingTimerCount, 0)
        environment.advance(to: 1_001_000.0)
        XCTAssertEqual(updates, 0)
    }

    func testDeallocatedManagerStopsTimerAndListener() {
        let environment = FakeEnvironment(timestamp: 1_000_000.0)
        var updates = 0
        var manager: PeerPresenceStatusManager? = PeerPresenceStatusManager(mode: .onlineState, environment: environment, update: {
            updates += 1
        })
        manager?.reset(presence: present(1_000_010), timeDifference: 0)
        XCTAssertEqual(environment.pendingTimerCount, 1)
        manager = nil
        XCTAssertEqual(environment.pendingTimerCount, 0)
        environment.isApplicationInBackground = true
        environment.isApplicationInBackground = false
        XCTAssertEqual(updates, 0)
    }
}
