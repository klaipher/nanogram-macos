import Foundation
import XCTest
@testable import NanogramRuntime

final class CacheMaintenanceSchedulerTests: XCTestCase {
    private final class FakeActivity: BackgroundActivity {
        var shouldDefer = false
        var scheduledBlock: ((@escaping (NSBackgroundActivityScheduler.Result) -> Void) -> Void)?
        var invalidated = false

        func schedule(_ block: @escaping (@escaping (NSBackgroundActivityScheduler.Result) -> Void) -> Void) {
            self.scheduledBlock = block
        }

        func invalidate() {
            self.invalidated = true
        }

        func fire() -> NSBackgroundActivityScheduler.Result? {
            var result: NSBackgroundActivityScheduler.Result?
            let done = DispatchSemaphore(value: 0)
            self.scheduledBlock?({ value in
                result = value
                done.signal()
            })
            XCTAssertEqual(done.wait(timeout: .now() + 10.0), .success)
            return result
        }
    }

    func testEachFireRunsEveryJobInOrderAndFinishes() {
        let activity = FakeActivity()
        var log: [String] = []
        let scheduler = CacheMaintenanceScheduler(activity: activity, jobs: { completion in
            completion([
                { done in log.append("a"); done() },
                { done in log.append("b"); done() }
            ])
        })
        XCTAssertEqual(activity.fire(), .finished)
        XCTAssertEqual(activity.fire(), .finished)
        XCTAssertEqual(log, ["a", "b", "a", "b"])
        withExtendedLifetime(scheduler) {}
    }

    func testDeferringStopsBeforeTheNextJob() {
        let activity = FakeActivity()
        var log: [String] = []
        let scheduler = CacheMaintenanceScheduler(activity: activity, jobs: { completion in
            completion([
                { done in log.append("a"); activity.shouldDefer = true; done() },
                { done in log.append("b"); done() }
            ])
        })
        XCTAssertEqual(activity.fire(), .deferred)
        XCTAssertEqual(log, ["a"])
        withExtendedLifetime(scheduler) {}
    }

    func testAlreadyDeferredRunsNothing() {
        let activity = FakeActivity()
        activity.shouldDefer = true
        var ran = false
        let scheduler = CacheMaintenanceScheduler(activity: activity, jobs: { completion in
            completion([{ done in ran = true; done() }])
        })
        XCTAssertEqual(activity.fire(), .deferred)
        XCTAssertFalse(ran)
        withExtendedLifetime(scheduler) {}
    }

    func testNoAccountsFinishes() {
        let activity = FakeActivity()
        let scheduler = CacheMaintenanceScheduler(activity: activity, jobs: { completion in
            completion([])
        })
        XCTAssertEqual(activity.fire(), .finished)
        withExtendedLifetime(scheduler) {}
    }

    func testJobsMayCompleteOnAnotherQueue() {
        let activity = FakeActivity()
        let scheduler = CacheMaintenanceScheduler(activity: activity, jobs: { completion in
            completion([
                { done in DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: done) },
                { done in DispatchQueue.global().async(execute: done) }
            ])
        })
        XCTAssertEqual(activity.fire(), .finished)
        withExtendedLifetime(scheduler) {}
    }

    func testReleasingTheSchedulerInvalidatesTheActivity() {
        let activity = FakeActivity()
        var scheduler: CacheMaintenanceScheduler? = CacheMaintenanceScheduler(activity: activity, jobs: { completion in
            completion([])
        })
        XCTAssertNotNil(scheduler)
        XCTAssertNotNil(activity.scheduledBlock)
        scheduler = nil
        XCTAssertTrue(activity.invalidated)
    }

    func testTheSystemActivityIsConfiguredForIdleMaintenance() {
        let scheduler = CacheMaintenanceScheduler.makeSystemScheduler(bundleIdentifier: "org.example.App")
        XCTAssertEqual(scheduler.identifier, "org.example.App.cache-eviction")
        XCTAssertTrue(scheduler.repeats)
        XCTAssertEqual(scheduler.interval, 6 * 60 * 60)
        XCTAssertEqual(scheduler.tolerance, 2 * 60 * 60)
        XCTAssertEqual(scheduler.qualityOfService, .background)
    }
}
