import Foundation
import XCTest
@testable import NanogramRuntime

final class PasslockMonitorTests: XCTestCase {
    private final class Environment {
        var wall: Double = 1_000_000
        var idle: Double = 0
        var locks = 0
        var timers: [(delay: Double, fire: () -> Void, cancelled: Bool)] = []

        var armed: [Double] {
            return self.timers.filter { !$0.cancelled }.map { $0.delay }
        }

        func monitor(timeout: Int32) -> PasslockMonitor {
            return PasslockMonitor(timeout: timeout, wallClock: { [unowned self] in self.wall }, idleTime: { [unowned self] in self.idle }, resignedAt: { nil }, schedule: { [unowned self] delay, fire in
                let index = self.timers.count
                self.timers.append((delay, fire, false))
                return { [unowned self] in
                    self.timers[index].cancelled = true
                }
            }, lock: { [unowned self] in
                self.locks += 1
            })
        }

        func awake(_ seconds: Double, input: Bool = false) {
            self.wall += seconds
            self.idle = input ? 0 : self.idle + seconds
        }

        func fireArmed() {
            guard let index = self.timers.indices.last(where: { !self.timers[$0].cancelled }) else {
                return
            }
            self.timers[index].cancelled = true
            self.timers[index].fire()
        }
    }

    func testAnHourTimeoutLocksOnWakeAfterANightAsleep() {
        let env = Environment()
        let monitor = env.monitor(timeout: 3600)
        monitor.start()
        XCTAssertEqual(env.armed, [3601])
        env.awake(300)
        monitor.systemWillSleep()
        env.wall += 8 * 3600
        env.idle = 0
        monitor.systemDidWake()
        XCTAssertEqual(env.locks, 1, "the timer's clock stopped during sleep; the wake must lock")
        XCTAssertEqual(env.armed, [])
    }

    func testAShortSleepCountsTowardsTheTimeout() {
        let env = Environment()
        let monitor = env.monitor(timeout: 3600)
        monitor.start()
        env.awake(300)
        monitor.systemWillSleep()
        env.wall += 600
        env.idle = 0
        monitor.systemDidWake()
        XCTAssertEqual(env.locks, 0)
        XCTAssertEqual(env.armed, [3600 - 900 + 1])
    }

    func testAWakeWithoutASleepNoticeChecksTheIdleTime() {
        let env = Environment()
        let monitor = env.monitor(timeout: 3600)
        monitor.start()
        env.wall += 4000
        env.idle = 4000
        monitor.systemDidWake()
        XCTAssertEqual(env.locks, 1)
    }

    func testTheTimerLocksOnceAndInputRearmsIt() {
        let env = Environment()
        let monitor = env.monitor(timeout: 60)
        monitor.start()
        env.awake(61, input: true)
        env.idle = 10
        env.fireArmed()
        XCTAssertEqual(env.locks, 0)
        XCTAssertEqual(env.armed, [51])
        env.awake(51)
        env.fireArmed()
        XCTAssertEqual(env.locks, 1)
        monitor.systemWillSleep()
        env.wall += 3600
        monitor.systemDidWake()
        XCTAssertEqual(env.locks, 1)
        XCTAssertEqual(env.armed, [])
    }

    func testStopCancelsTheTimerAndIgnoresWake() {
        let env = Environment()
        let monitor = env.monitor(timeout: 60)
        monitor.start()
        monitor.systemWillSleep()
        monitor.stop()
        XCTAssertEqual(env.armed, [])
        env.wall += 3600
        env.idle = 3600
        monitor.systemDidWake()
        XCTAssertEqual(env.locks, 0)
        XCTAssertEqual(env.armed, [])
    }
}
