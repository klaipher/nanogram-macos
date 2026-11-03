import XCTest
@testable import TGUIKit

final class PerformanceSignpostsTests: XCTestCase {
    private struct Failure: Error {}

    func testIntervalReturnsTheBodyValue() {
        var calls = 0
        let value = PerformanceSignposts.interval("test") { () -> Int in
            calls += 1
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(calls, 1)
    }

    func testIntervalRethrowsAndNests() {
        XCTAssertThrowsError(try PerformanceSignposts.interval("outer") {
            try PerformanceSignposts.interval("inner") {
                throw Failure()
            }
        })
    }

    func testManualIntervalsBalance() {
        let state = PerformanceSignposts.begin("manual")
        PerformanceSignposts.end("manual", state)
        XCTAssertEqual(PerformanceSignposts.category, "Performance")
    }
}
