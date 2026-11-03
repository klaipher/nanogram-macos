import XCTest
import AVKit
import AVFoundation
import NanogramDebug
@testable import NanogramRuntime

private final class FakePlayer: SystemPictureInPicturePlayer {
    var isPlaying = true
    var duration: Double = 120
    var currentTime: Double = 30
    var calls: [String] = []

    func play() {
        self.calls.append("play")
        self.isPlaying = true
    }

    func pause() {
        self.calls.append("pause")
        self.isPlaying = false
    }

    func seek(_ timestamp: Double) {
        self.calls.append("seek \(timestamp)")
        self.currentTime = timestamp
    }
}

final class SystemPictureInPictureTests: XCTestCase {
    func testDebugSwitchIsOffByDefault() {
        let suite = "SystemPictureInPictureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NanogramDebugSettings(defaults: defaults)
        guard case let .toggle(defaultValue) = SystemPictureInPicture.debugOption.kind else {
            return XCTFail("toggle expected")
        }
        XCTAssertFalse(defaultValue)
        XCTAssertFalse(SystemPictureInPicture.isEnabled(in: settings))
        settings.register(SystemPictureInPicture.debugOption)
        XCTAssertFalse(SystemPictureInPicture.isEnabled(in: settings))
        settings.set(SystemPictureInPicture.debugOption.id, bool: true)
        XCTAssertTrue(SystemPictureInPicture.isEnabled(in: settings))
    }

    func testPlaybackControlsReachThePlayer() throws {
        guard #available(macOS 12.0, *) else {
            throw XCTSkip("AVPictureInPictureController content sources need macOS 12")
        }
        let player = FakePlayer()
        let pip = try XCTUnwrap(SystemPictureInPicture(layer: AVSampleBufferDisplayLayer(), player: player))
        let controller = pip.controller

        XCTAssertFalse(pip.pictureInPictureControllerIsPlaybackPaused(controller))
        pip.pictureInPictureController(controller, setPlaying: false)
        XCTAssertTrue(pip.pictureInPictureControllerIsPlaybackPaused(controller))
        pip.pictureInPictureController(controller, setPlaying: true)
        XCTAssertEqual(player.calls, ["pause", "play"])

        let range = pip.pictureInPictureControllerTimeRangeForPlayback(controller)
        XCTAssertEqual(range.start.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(range.duration.seconds, 120, accuracy: 0.001)

        var skipped = false
        pip.pictureInPictureController(controller, skipByInterval: CMTime(seconds: 15, preferredTimescale: 600), completion: { skipped = true })
        XCTAssertTrue(skipped)
        XCTAssertEqual(player.calls.last, "seek 45.0")
        pip.pictureInPictureController(controller, skipByInterval: CMTime(seconds: -60, preferredTimescale: 600), completion: {})
        XCTAssertEqual(player.calls.last, "seek 0.0")
        pip.pictureInPictureController(controller, skipByInterval: CMTime(seconds: 500, preferredTimescale: 600), completion: {})
        XCTAssertEqual(player.calls.last, "seek 120.0")

        player.duration = 0
        let unknown = pip.pictureInPictureControllerTimeRangeForPlayback(controller)
        XCTAssertTrue(unknown.duration.isPositiveInfinity)
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testStartShowsSystemPictureInPictureWithoutFallingBack() throws {
        guard #available(macOS 12.0, *) else {
            throw XCTSkip("AVPictureInPictureController content sources need macOS 12")
        }
        let pip = try XCTUnwrap(SystemPictureInPicture(layer: AVSampleBufferDisplayLayer(), player: FakePlayer()))
        var failures = 0
        pip.onFailure = { failures += 1 }
        pip.start(timeout: 5)
        self.spin(until: { pip.controller.isPictureInPictureActive || failures > 0 }, timeout: 10)
        guard pip.controller.isPictureInPictureActive else {
            throw XCTSkip("the system did not start picture-in-picture in this session (failures: \(failures))")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(5.5))
        XCTAssertEqual(failures, 0)
        pip.stop()
        self.spin(until: { !pip.controller.isPictureInPictureActive }, timeout: 3)
    }

    func testFailureToStartFallsBackOnce() throws {
        guard #available(macOS 12.0, *) else {
            throw XCTSkip("AVPictureInPictureController content sources need macOS 12")
        }
        let pip = try XCTUnwrap(SystemPictureInPicture(layer: AVSampleBufferDisplayLayer(), player: FakePlayer()))
        var failures = 0
        pip.onFailure = { failures += 1 }
        pip.pictureInPictureController(pip.controller, failedToStartPictureInPictureWithError: NSError(domain: "test", code: 1))
        pip.pictureInPictureController(pip.controller, failedToStartPictureInPictureWithError: NSError(domain: "test", code: 1))
        XCTAssertEqual(failures, 1)
    }

    func testRestoreAsksTheAppAndStopNotifiesOnce() throws {
        guard #available(macOS 12.0, *) else {
            throw XCTSkip("AVPictureInPictureController content sources need macOS 12")
        }
        let pip = try XCTUnwrap(SystemPictureInPicture(layer: AVSampleBufferDisplayLayer(), player: FakePlayer()))
        var restored = 0
        var stops = 0
        pip.onRestore = { restored += 1 }
        pip.onStop = { stops += 1 }
        var answer: Bool?
        pip.pictureInPictureController(pip.controller, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { answer = $0 })
        XCTAssertEqual(answer, true)
        XCTAssertEqual(restored, 1)
        pip.pictureInPictureControllerDidStopPictureInPicture(pip.controller)
        pip.pictureInPictureControllerDidStopPictureInPicture(pip.controller)
        XCTAssertEqual(stops, 1)
    }
}
