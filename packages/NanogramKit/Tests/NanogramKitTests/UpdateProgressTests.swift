import XCTest
@testable import NanogramKit

final class UpdateProgressTests: XCTestCase {
    func test_percentText_unknownTotal_isEmpty() {
        XCTAssertEqual(UpdateProgress.percentText(current: 0, total: 0), "")
        XCTAssertEqual(UpdateProgress.percentText(current: 500, total: 0), "")
        XCTAssertEqual(UpdateProgress.percentText(current: 10, total: -1), "")
    }

    func test_percentText_knownTotal_isWholePercent() {
        XCTAssertEqual(UpdateProgress.percentText(current: 0, total: 1000), "0%")
        XCTAssertEqual(UpdateProgress.percentText(current: 255, total: 1000), "25%")
        XCTAssertEqual(UpdateProgress.percentText(current: 1000, total: 1000), "100%")
    }

    func test_percentText_isClampedTo0Through100() {
        XCTAssertEqual(UpdateProgress.percentText(current: 1500, total: 1000), "100%")
        XCTAssertEqual(UpdateProgress.percentText(current: -5, total: 1000), "0%")
    }

    func test_percentText_hugeSizes_doNotOverflow() {
        XCTAssertEqual(UpdateProgress.percentText(current: Int.max, total: Int.max), "100%")
        XCTAssertEqual(UpdateProgress.percentText(current: Int.max / 2, total: Int.max), "50%")
    }

    func test_percentText_downloadStartedWithoutLength_isEmpty() {
        var flow = UpdateFlow<String>()
        flow.apply(.found("2.0"))
        flow.apply(.downloadStarted)
        guard case let .downloading(_, received, expected) = flow.phase else {
            return XCTFail("expected downloading, got \(flow.phase)")
        }
        XCTAssertEqual(UpdateProgress.percentText(current: Int(clamping: received), total: Int(clamping: expected)), "")
    }
}
