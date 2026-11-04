import XCTest
@testable import TGUIKit

final class PrewarmedSlotTests: XCTestCase {
    func testTakeUsesPrewarmedValueWithoutBuildingAgain() {
        var built = 0
        let slot = PrewarmedSlot<Int> { built += 1; return built }
        slot.prewarm()
        slot.prewarm()
        XCTAssertEqual(built, 1)
        XCTAssertTrue(slot.isWarm)
        XCTAssertEqual(slot.take(), 1)
        XCTAssertEqual(built, 1)
        XCTAssertFalse(slot.isWarm)
    }

    func testTakeBuildsOnDemandWhenCold() {
        var built = 0
        let slot = PrewarmedSlot<Int> { built += 1; return built }
        XCTAssertEqual(slot.take(), 1)
        XCTAssertEqual(slot.take(), 2)
    }

    func testDiscardDropsWarmValue() {
        var built = 0
        let slot = PrewarmedSlot<Int> { built += 1; return built }
        slot.prewarm()
        slot.discard()
        XCTAssertFalse(slot.isWarm)
        XCTAssertEqual(slot.take(), 2)
    }
}
