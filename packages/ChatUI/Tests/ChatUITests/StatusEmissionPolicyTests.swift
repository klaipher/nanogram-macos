import XCTest
@testable import TelegramMedia

final class StatusEmissionPolicyTests: XCTestCase {
    private func emit(hasPrevious: Bool = true, differs: Bool = false, playing: Bool = false, now: Double = 10.0, last: Double = 10.0, timestampChanged: Bool = false) -> Bool {
        return StatusEmissionPolicy.shouldEmit(hasPreviousStatus: hasPrevious, differsBeyondTiming: differs, isPlayingLike: playing, now: now, lastEmitTimestamp: last, timestampChanged: timestampChanged)
    }

    func testFirstStatusIsAlwaysEmitted() {
        XCTAssertTrue(self.emit(hasPrevious: false))
    }

    func testTwoIdenticalPausedUpdatesEmitOnce() {
        XCTAssertFalse(self.emit(playing: false, timestampChanged: false))
    }

    func testPausedSeekEmits() {
        XCTAssertTrue(self.emit(playing: false, timestampChanged: true))
    }

    func testFieldChangeEmitsImmediately() {
        XCTAssertTrue(self.emit(differs: true, playing: true, now: 10.01, last: 10.0))
    }

    func testPlayingIsLimitedToTheHeartbeat() {
        XCTAssertFalse(self.emit(playing: true, now: 10.05, last: 10.0, timestampChanged: true))
        XCTAssertTrue(self.emit(playing: true, now: 10.2, last: 10.0, timestampChanged: true))
    }
}
