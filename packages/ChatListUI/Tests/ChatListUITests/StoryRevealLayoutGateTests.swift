import XCTest
@testable import ChatListUI

final class StoryRevealLayoutGateTests: XCTestCase {
    func testSkipsUnchangedFractionAndState() {
        var gate = StoryRevealLayoutGate<Int>()
        XCTAssertTrue(gate.shouldLayout(fraction: 0.5, state: 1))
        XCTAssertFalse(gate.shouldLayout(fraction: 0.5, state: 1))
        XCTAssertTrue(gate.shouldLayout(fraction: 0.6, state: 1))
        XCTAssertTrue(gate.shouldLayout(fraction: 0.6, state: 2))
        XCTAssertFalse(gate.shouldLayout(fraction: 0.6, state: 2))
    }

    func testForceAlwaysLaysOut() {
        var gate = StoryRevealLayoutGate<Int>()
        XCTAssertTrue(gate.shouldLayout(fraction: 0, state: 0))
        XCTAssertTrue(gate.shouldLayout(fraction: 0, state: 0, force: true))
        XCTAssertFalse(gate.shouldLayout(fraction: 0, state: 0))
    }
}
