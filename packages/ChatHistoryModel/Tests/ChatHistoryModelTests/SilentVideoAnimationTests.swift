import Foundation
import XCTest
@testable import ChatHistoryModel

final class SilentVideoAnimationTests: XCTestCase {
    func testSmallSilentMp4IsAnimation() {
        XCTAssertTrue(Sender.isAnimatedVideo(hasAudio: false, fileSize: 2 * 1024 * 1024, inCollage: false, isEditedPhoto: false))
    }

    func testLargeSilentMp4IsAVideo() {
        XCTAssertFalse(Sender.isAnimatedVideo(hasAudio: false, fileSize: 187 * 1024 * 1024, inCollage: false, isEditedPhoto: false))
    }

    func testSilentMp4AtTheLimitIsAVideo() {
        XCTAssertFalse(Sender.isAnimatedVideo(hasAudio: false, fileSize: 10 * 1024 * 1024, inCollage: false, isEditedPhoto: false))
    }

    func testASmallSilentVideoIsAnimationWhateverItsContainer() {
        XCTAssertTrue(Sender.isAnimatedVideo(hasAudio: false, fileSize: 4 * 1024 * 1024, inCollage: false, isEditedPhoto: false))
    }

    func testUnknownSizeIsAVideo() {
        XCTAssertFalse(Sender.isAnimatedVideo(hasAudio: false, fileSize: nil, inCollage: false, isEditedPhoto: false))
    }

    func testVideoWithAudioIsNeverAnimation() {
        XCTAssertFalse(Sender.isAnimatedVideo(hasAudio: true, fileSize: 1024, inCollage: false, isEditedPhoto: false))
    }

    func testCollageAndEditedPhotoStayVideos() {
        XCTAssertFalse(Sender.isAnimatedVideo(hasAudio: false, fileSize: 1024, inCollage: true, isEditedPhoto: false))
        XCTAssertFalse(Sender.isAnimatedVideo(hasAudio: false, fileSize: 1024, inCollage: false, isEditedPhoto: true))
    }
}
