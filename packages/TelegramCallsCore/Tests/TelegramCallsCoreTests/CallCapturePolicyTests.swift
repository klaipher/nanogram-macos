import XCTest
import TelegramCore
@testable import TelegramCallsCore

final class CallCapturePolicyTests: XCTestCase {
    func testScreenCaptureFailureOfTheCurrentCapturerStopsTheShare() {
        XCTAssertEqual(callCaptureFailureAction(isCurrentCapturer: true, isScreenCapture: true), .stopScreenCapture)
    }

    func testCameraFailureOfTheCurrentCapturerStopsTheVideo() {
        XCTAssertEqual(callCaptureFailureAction(isCurrentCapturer: true, isScreenCapture: false), .stopVideo)
    }

    func testFailureOfAReplacedCapturerIsIgnored() {
        XCTAssertEqual(callCaptureFailureAction(isCurrentCapturer: false, isScreenCapture: true), .ignore)
        XCTAssertEqual(callCaptureFailureAction(isCurrentCapturer: false, isScreenCapture: false), .ignore)
    }

    func testCameraSwitchFollowsTheCameraOnlyWhileTheCameraIsSent() {
        XCTAssertEqual(callCameraSwitchTarget(newCameraId: "cam2", hasCapturer: true, isScreenCapture: false, isVideoAvailable: true), "cam2")
        XCTAssertNil(callCameraSwitchTarget(newCameraId: "cam2", hasCapturer: true, isScreenCapture: true, isVideoAvailable: true))
        XCTAssertNil(callCameraSwitchTarget(newCameraId: "cam2", hasCapturer: false, isScreenCapture: false, isVideoAvailable: true))
        XCTAssertNil(callCameraSwitchTarget(newCameraId: "cam2", hasCapturer: true, isScreenCapture: false, isVideoAvailable: false))
        XCTAssertNil(callCameraSwitchTarget(newCameraId: nil, hasCapturer: true, isScreenCapture: false, isVideoAvailable: true))
    }

    func testSwitchingBetweenCameraAndScreenReattachesTheCapturer() {
        XCTAssertTrue(callCaptureNeedsReattach(hasCapturer: true, wasScreen: false, toScreen: true))
        XCTAssertTrue(callCaptureNeedsReattach(hasCapturer: true, wasScreen: true, toScreen: false))
    }

    func testNoReattachWithoutACapturerOrWhenTheSourceKindStays() {
        XCTAssertFalse(callCaptureNeedsReattach(hasCapturer: false, wasScreen: false, toScreen: true))
        XCTAssertFalse(callCaptureNeedsReattach(hasCapturer: false, wasScreen: true, toScreen: false))
        XCTAssertFalse(callCaptureNeedsReattach(hasCapturer: true, wasScreen: false, toScreen: false))
        XCTAssertFalse(callCaptureNeedsReattach(hasCapturer: true, wasScreen: true, toScreen: true))
    }

    func testTerminalStatesReleaseCapture() {
        XCTAssertTrue(callSessionReleasesCapture(.terminated(id: nil, reason: .ended(.hungUp), options: [])))
        XCTAssertTrue(callSessionReleasesCapture(.dropping(reason: .ended(.hungUp))))
        XCTAssertFalse(callSessionReleasesCapture(.ringing))
        XCTAssertFalse(callSessionReleasesCapture(.accepting))
        XCTAssertFalse(callSessionReleasesCapture(.requesting(ringing: true)))
        XCTAssertFalse(callSessionReleasesCapture(.switchedToConference(slug: "x")))
    }

    func testCaptureIsRefusedOnceTheCallIsOver() {
        XCTAssertTrue(callSessionAllowsCapture(nil))
        XCTAssertTrue(callSessionAllowsCapture(.ringing))
        XCTAssertTrue(callSessionAllowsCapture(.requesting(ringing: false)))
        XCTAssertFalse(callSessionAllowsCapture(.terminated(id: nil, reason: .ended(.hungUp), options: [])))
        XCTAssertFalse(callSessionAllowsCapture(.dropping(reason: .ended(.hungUp))))
        XCTAssertFalse(callSessionAllowsCapture(.switchedToConference(slug: "x")))
    }
}
