import XCTest
@testable import TelegramMedia

final class VP9SessionHoldPolicyTests: XCTestCase {
    func testActivePlaybackKeepsSessions() {
        XCTAssertFalse(VP9SessionHoldPolicy.shouldRelease(streamEnded: false, frameCacheComplete: false, hiddenFor: nil))
        XCTAssertFalse(VP9SessionHoldPolicy.shouldRelease(streamEnded: false, frameCacheComplete: false, hiddenFor: 0.5))
    }

    func testCompleteFrameCacheReleases() {
        XCTAssertTrue(VP9SessionHoldPolicy.shouldRelease(streamEnded: false, frameCacheComplete: true, hiddenFor: nil))
    }

    func testEndOfStreamReleases() {
        XCTAssertTrue(VP9SessionHoldPolicy.shouldRelease(streamEnded: true, frameCacheComplete: false, hiddenFor: nil))
    }

    func testHiddenReleasesAfterTwoSeconds() {
        XCTAssertFalse(VP9SessionHoldPolicy.shouldRelease(streamEnded: false, frameCacheComplete: false, hiddenFor: 1.99))
        XCTAssertTrue(VP9SessionHoldPolicy.shouldRelease(streamEnded: false, frameCacheComplete: false, hiddenFor: 2.0))
    }

    func testHiddenGateReleasesOnlyTheLatestStillHiddenSchedule() {
        var gate = VP9HiddenReleaseGate()
        let first = gate.hide()
        XCTAssertTrue(gate.shouldRelease(scheduledGeneration: first))
        gate.show()
        XCTAssertFalse(gate.shouldRelease(scheduledGeneration: first))
        let second = gate.hide()
        XCTAssertFalse(gate.shouldRelease(scheduledGeneration: first))
        XCTAssertTrue(gate.shouldRelease(scheduledGeneration: second))
    }

    func testShownGateNeverReleases() {
        var gate = VP9HiddenReleaseGate()
        let scheduled = gate.hide()
        gate.show()
        XCTAssertFalse(gate.shouldRelease(scheduledGeneration: scheduled))
        XCTAssertFalse(gate.shouldRelease(scheduledGeneration: gate.generation))
    }
}
