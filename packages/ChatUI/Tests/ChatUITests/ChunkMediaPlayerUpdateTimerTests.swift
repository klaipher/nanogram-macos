import XCTest
@testable import TelegramMedia

final class ChunkMediaPlayerUpdateTimerTests: XCTestCase {
    private func interval(isPlaying: Bool = false, pendingSeek: Bool = false, pendingVideoFrame: Bool = false, didSeekOnce: Bool = true, isBuffering: Bool = false, isStarved: Bool = false, isNearEnd: Bool = false) -> Double? {
        return ChunkMediaPlayerV2.updateInterval(isPlaying: isPlaying, pendingSeek: pendingSeek, pendingVideoFrame: pendingVideoFrame, didSeekOnce: didSeekOnce, isBuffering: isBuffering, isStarved: isStarved, isNearEnd: isNearEnd)
    }

    func testPausedAndSettledPlayerDoesNotPoll() {
        XCTAssertNil(self.interval(isPlaying: false))
    }

    func testPausedPlayerWithPendingWorkStillPolls() {
        XCTAssertEqual(self.interval(isPlaying: false, pendingSeek: true), 1.0 / 60.0)
        XCTAssertEqual(self.interval(isPlaying: false, pendingVideoFrame: true), 1.0 / 60.0)
        XCTAssertEqual(self.interval(isPlaying: false, didSeekOnce: false), 1.0 / 60.0)
    }

    func testSteadyPlaybackPollsAtTenHertz() {
        XCTAssertEqual(self.interval(isPlaying: true), 1.0 / 10.0)
    }

    func testTransitionsPollAtSixtyHertz() {
        XCTAssertEqual(self.interval(isPlaying: true, isBuffering: true), 1.0 / 60.0)
        XCTAssertEqual(self.interval(isPlaying: true, isStarved: true), 1.0 / 60.0)
        XCTAssertEqual(self.interval(isPlaying: true, isNearEnd: true), 1.0 / 60.0)
    }

    func testToleranceIsAlwaysSetAndAtLeastTenPercent() {
        for interval in [1.0 / 60.0, 1.0 / 30.0, 1.0 / 10.0, 1.0 / 5.0, 1.0] {
            let tolerance = ChunkMediaPlayerV2.updateTimerTolerance(interval: interval)
            XCTAssertGreaterThanOrEqual(tolerance, 0.002)
            XCTAssertGreaterThanOrEqual(tolerance, interval * 0.1 - 1e-12)
        }
        XCTAssertEqual(ChunkMediaPlayerV2.updateTimerTolerance(interval: 0.001), 0.002)
    }

    func testOnlyTheFastCasesUseTheDisplayLink() {
        XCTAssertTrue(ChunkMediaPlayerV2.usesDisplayLink(interval: 1.0 / 60.0))
        XCTAssertTrue(ChunkMediaPlayerV2.usesDisplayLink(interval: 1.0 / 30.0))
        XCTAssertFalse(ChunkMediaPlayerV2.usesDisplayLink(interval: 1.0 / 10.0))
        XCTAssertFalse(ChunkMediaPlayerV2.usesDisplayLink(interval: 1.0))
    }

    func testEveryFastCaseKeepsASlowSafetyTimer() {
        XCTAssertEqual(ChunkMediaPlayerV2.displayLinkSafetyInterval, 1.0 / 10.0)
        XCTAssertGreaterThanOrEqual(ChunkMediaPlayerV2.updateTimerTolerance(interval: ChunkMediaPlayerV2.displayLinkSafetyInterval), 0.01 - 1e-12)
    }
}
