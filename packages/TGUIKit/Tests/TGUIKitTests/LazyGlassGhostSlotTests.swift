import XCTest
@testable import TGUIKit

final class LazyGlassGhostSlotTests: XCTestCase {
    private final class Dummy {}

    func testDoesNotCreateWhileNotNeeded() {
        var made = 0
        let slot = LazyGlassGhostSlot<Dummy>(make: { made += 1; return Dummy() }, attach: { _ in })
        XCTAssertNil(slot.resolve(isNeeded: false))
        XCTAssertNil(slot.resolve(isNeeded: false))
        XCTAssertEqual(made, 0)
        XCTAssertFalse(slot.isCreated)
    }

    func testCreatesOnceOnFirstNeedAndAttachesBeforeReturning() {
        var attached: [Dummy] = []
        var made = 0
        let slot = LazyGlassGhostSlot<Dummy>(make: { made += 1; return Dummy() }, attach: { attached.append($0) })
        let first = slot.resolve(isNeeded: true)
        XCTAssertNotNil(first)
        XCTAssertEqual(attached.count, 1)
        XCTAssertTrue(attached[0] === first)
        XCTAssertTrue(slot.resolve(isNeeded: true) === first)
        XCTAssertEqual(made, 1)
        XCTAssertEqual(slot.creationCount, 1)
    }

    func testExistingGhostIsReturnedEvenWhenNoLongerNeeded() {
        let slot = LazyGlassGhostSlot<Dummy>(make: { Dummy() }, attach: { _ in })
        let first = slot.resolve(isNeeded: true)
        XCTAssertTrue(slot.resolve(isNeeded: false) === first)
        XCTAssertEqual(slot.creationCount, 1)
    }
}
