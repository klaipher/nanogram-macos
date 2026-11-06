import XCTest
@testable import ChatUI

final class ChatControllerLifetimeTests: XCTestCase {
    func testLiveCountFollowsCreationsAndDeinits() {
        let counter = LiveInstanceCounter()
        XCTAssertEqual(counter.instanceCreated().live, 1)
        XCTAssertEqual(counter.instanceCreated().live, 2)
        XCTAssertEqual(counter.instanceDeinitialized().live, 1)
        XCTAssertEqual(counter.snapshot, LiveInstanceCounter.Snapshot(live: 1, created: 2, deinitialized: 1, peak: 2))
    }

    func testAbandonedInstancesShowAsLiveAfterEveryCloseCycle() {
        let counter = LiveInstanceCounter()
        for _ in 0 ..< 18 {
            counter.instanceCreated()
        }
        XCTAssertEqual(counter.snapshot.live, 18)
        XCTAssertEqual(counter.snapshot.deinitialized, 0)
        for _ in 0 ..< 17 {
            counter.instanceDeinitialized()
        }
        XCTAssertEqual(counter.snapshot.live, 1)
        XCTAssertEqual(counter.snapshot.peak, 18)
    }

    func testLiveCountNeverGoesNegative() {
        let counter = LiveInstanceCounter()
        XCTAssertEqual(counter.instanceDeinitialized().live, 0)
        XCTAssertEqual(counter.instanceCreated().live, 1)
    }

    func testCountsAreConsistentUnderConcurrentUse() {
        let counter = LiveInstanceCounter()
        DispatchQueue.concurrentPerform(iterations: 400) { _ in
            counter.instanceCreated()
            counter.instanceDeinitialized()
        }
        XCTAssertEqual(counter.snapshot.live, 0)
        XCTAssertEqual(counter.snapshot.created, 400)
        XCTAssertEqual(counter.snapshot.deinitialized, 400)
    }
}
