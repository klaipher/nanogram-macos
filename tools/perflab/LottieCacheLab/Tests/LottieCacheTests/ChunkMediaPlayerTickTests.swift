import XCTest
@testable import TelegramMedia

final class ChunkMediaPlayerTickTests: XCTestCase {
    private func interval(isPlaying: Bool = true, pendingSeek: Bool = false, pendingVideoFrame: Bool = false, didSeekOnce: Bool = true, isBuffering: Bool = false, isStarved: Bool = false, isNearEnd: Bool = false) -> Double? {
        return ChunkMediaPlayerV2.updateInterval(isPlaying: isPlaying, pendingSeek: pendingSeek, pendingVideoFrame: pendingVideoFrame, didSeekOnce: didSeekOnce, isBuffering: isBuffering, isStarved: isStarved, isNearEnd: isNearEnd)
    }

    func testSteadyPlaybackTicksAtTenHertzNotSixty() {
        XCTAssertEqual(interval() ?? 0.0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(10.0 / (interval() ?? 1.0), 100, accuracy: 0.01)
    }

    func testEveryTransitionKeepsTheSixtyHertzTick() {
        let fast = 1.0 / 60.0
        XCTAssertEqual(interval(pendingSeek: true) ?? 0.0, fast, accuracy: 0.0001)
        XCTAssertEqual(interval(pendingVideoFrame: true) ?? 0.0, fast, accuracy: 0.0001)
        XCTAssertEqual(interval(didSeekOnce: false) ?? 0.0, fast, accuracy: 0.0001)
        XCTAssertEqual(interval(isBuffering: true) ?? 0.0, fast, accuracy: 0.0001)
        XCTAssertEqual(interval(isStarved: true) ?? 0.0, fast, accuracy: 0.0001)
        XCTAssertEqual(interval(isNearEnd: true) ?? 0.0, fast, accuracy: 0.0001)
        XCTAssertEqual(interval(isPlaying: false, pendingSeek: true) ?? 0.0, fast, accuracy: 0.0001)
    }

    func testPausedAndSettledDoesNotTick() {
        XCTAssertNil(interval(isPlaying: false))
        XCTAssertNil(interval(isPlaying: false, isBuffering: true, isStarved: true, isNearEnd: true))
    }
}
