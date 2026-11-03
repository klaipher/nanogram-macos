import XCTest
import IOKit.pwr_mgt
@testable import TGUIKit

final class ScreenSleepAssertionTests: XCTestCase {
    func testOnlyVisibleVideoKeepsTheDisplayAwake() {
        XCTAssertTrue(ScreenSleepAssertion.isNeeded(hasVisibleVideo: true, isWindowVisible: true))
        XCTAssertFalse(ScreenSleepAssertion.isNeeded(hasVisibleVideo: false, isWindowVisible: true))
        XCTAssertFalse(ScreenSleepAssertion.isNeeded(hasVisibleVideo: true, isWindowVisible: false))
        XCTAssertFalse(ScreenSleepAssertion.isNeeded(hasVisibleVideo: false, isWindowVisible: false))
    }

    func testUpdatesCreateAndReleaseOneAssertionAtATime() {
        var created: [String] = []
        var released: [IOPMAssertionID] = []
        var next: IOPMAssertionID = 40
        var assertion: ScreenSleepAssertion? = ScreenSleepAssertion(reason: "Call", create: { reason in
            created.append(reason)
            next += 1
            return next
        }, release: { id in
            released.append(id)
        })
        assertion?.update(needed: false)
        XCTAssertEqual(created.count, 0)
        assertion?.update(needed: true)
        assertion?.update(needed: true)
        XCTAssertEqual(created, ["Call"])
        XCTAssertTrue(assertion?.isHeld ?? false)
        assertion?.update(needed: false)
        assertion?.update(needed: false)
        XCTAssertEqual(released, [41])
        assertion?.update(needed: true)
        XCTAssertEqual(created.count, 2)
        assertion = nil
        XCTAssertEqual(released, [41, 42])
    }

    func testAFailedCreateIsNotReleased() {
        var released = 0
        let assertion = ScreenSleepAssertion(reason: "Call", create: { _ in nil }, release: { _ in released += 1 })
        assertion.update(needed: true)
        XCTAssertFalse(assertion.isHeld)
        assertion.update(needed: false)
        XCTAssertEqual(released, 0)
    }
}
