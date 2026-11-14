import XCTest
@testable import MediaRecorderUI

final class RoundVideoEncodingPolicyTests: XCTestCase {
    func testSideIsAtLeast480AndEven() {
        XCTAssertEqual(RoundVideoEncodingPolicy.side(serverDiameter: 384), 480)
        XCTAssertEqual(RoundVideoEncodingPolicy.side(serverDiameter: 0), 480)
        XCTAssertEqual(RoundVideoEncodingPolicy.side(serverDiameter: 480), 480)
        XCTAssertEqual(RoundVideoEncodingPolicy.side(serverDiameter: 511), 510)
        XCTAssertEqual(RoundVideoEncodingPolicy.side(serverDiameter: 512), 512)
        XCTAssertEqual(RoundVideoEncodingPolicy.side(serverDiameter: 4096), 640)
    }

    func testBitratesHaveFloors() {
        XCTAssertEqual(RoundVideoEncodingPolicy.videoBitrateKbps(server: 1000), 1200)
        XCTAssertEqual(RoundVideoEncodingPolicy.videoBitrateKbps(server: 1200), 1200)
        XCTAssertEqual(RoundVideoEncodingPolicy.videoBitrateKbps(server: 2000), 2000)
        XCTAssertEqual(RoundVideoEncodingPolicy.audioBitrateKbps(server: 32), 64)
        XCTAssertEqual(RoundVideoEncodingPolicy.audioBitrateKbps(server: 96), 96)
    }

    func testDefaultServerConfigGivesIosSettings() {
        let config = VideoMessageConfig.defaultValue
        XCTAssertEqual(RoundVideoEncodingPolicy.side(serverDiameter: config.diameter), 480)
        XCTAssertEqual(RoundVideoEncodingPolicy.videoBitrateKbps(server: config.videoBitrate), 1200)
        XCTAssertEqual(RoundVideoEncodingPolicy.frameRate, 30)
    }

    func testCaptureTargetHasHeadroom() {
        XCTAssertEqual(RoundVideoEncodingPolicy.targetCaptureShortSide(side: 480), 600)
        XCTAssertEqual(RoundVideoEncodingPolicy.targetCaptureShortSide(side: 640), 800)
    }

    func testBestCaptureFormatPicksSmallestLargeEnough() {
        typealias C = RoundVideoEncodingPolicy.CaptureFormatCandidate
        let formats = [C(shortSide: 1080, supportsFrameRate: true), C(shortSide: 480, supportsFrameRate: true), C(shortSide: 720, supportsFrameRate: true), C(shortSide: 600, supportsFrameRate: false)]
        XCTAssertEqual(RoundVideoEncodingPolicy.bestCaptureFormat(formats, side: 480), 2)
    }

    func testBestCaptureFormatFallsBackToLargestWithoutUpscaling() {
        typealias C = RoundVideoEncodingPolicy.CaptureFormatCandidate
        let formats = [C(shortSide: 240, supportsFrameRate: true), C(shortSide: 480, supportsFrameRate: true), C(shortSide: 360, supportsFrameRate: true)]
        XCTAssertEqual(RoundVideoEncodingPolicy.bestCaptureFormat(formats, side: 480), 1)
        XCTAssertNil(RoundVideoEncodingPolicy.bestCaptureFormat([C(shortSide: 720, supportsFrameRate: false)], side: 480))
        XCTAssertNil(RoundVideoEncodingPolicy.bestCaptureFormat([], side: 480))
    }

    func testEffectiveSideNeverUpscalesSource() {
        XCTAssertEqual(RoundVideoEncodingPolicy.effectiveSide(side: 480, sourceShortSide: 720), 480)
        XCTAssertEqual(RoundVideoEncodingPolicy.effectiveSide(side: 480, sourceShortSide: 480), 480)
        XCTAssertEqual(RoundVideoEncodingPolicy.effectiveSide(side: 480, sourceShortSide: 361), 360)
        XCTAssertEqual(RoundVideoEncodingPolicy.effectiveSide(side: 480, sourceShortSide: 0), 480)
    }
}
