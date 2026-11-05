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
}
