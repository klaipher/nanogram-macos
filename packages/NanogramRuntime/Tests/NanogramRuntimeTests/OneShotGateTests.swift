import XCTest
@testable import NanogramRuntime

final class OneShotGateTests: XCTestCase {
    func testThreeHundredFramesRunTheWorkOnceWithTheFirstValue() {
        let gate = OneShotGate()
        var runs: [Int] = []
        for frame in 0 ..< 300 {
            gate.run { runs.append(frame) }
        }
        XCTAssertEqual(runs, [0])
    }

    func testResetRearms() {
        let gate = OneShotGate()
        var runs = 0
        gate.run { runs += 1 }
        gate.reset()
        gate.run { runs += 1 }
        gate.run { runs += 1 }
        XCTAssertEqual(runs, 2)
    }
}
