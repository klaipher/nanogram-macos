import XCTest
@testable import NanogramRuntime

final class GalleryReleaseScheduleTests: XCTestCase {
    func testAPageChangeWhileAnUpdateIsQueuedReleasesNothingAndDefers() {
        var schedule = GalleryReleaseSchedule()
        let decision = schedule.note(itemCount: 5, index: 4, displayedIndex: 1, pending: true)
        XCTAssertEqual(decision.indices, [])
        XCTAssertTrue(schedule.isDeferred)
    }

    func testFlushNeverReleasesWhileTheUpdateIsStillPending() {
        var schedule = GalleryReleaseSchedule()
        _ = schedule.note(itemCount: 5, index: 4, displayedIndex: 1, pending: true)
        XCTAssertEqual(schedule.flush(itemCount: 5, displayedIndex: 1, pending: true), [])
        XCTAssertTrue(schedule.isDeferred)
    }

    func testFlushReleasesOnceAroundTheShownPhotoAfterTheUpdateIsApplied() {
        let items = ["X", "Y", "Z", "A", "B", "C", "D", "E"]
        var schedule = GalleryReleaseSchedule()
        _ = schedule.note(itemCount: 5, index: 4, displayedIndex: 1, pending: true)
        let released = schedule.flush(itemCount: items.count, displayedIndex: 4, pending: false)
        XCTAssertEqual(released.map { items[$0] }, ["X", "Y", "Z", "D", "E"])
        XCTAssertFalse(schedule.isDeferred)
        XCTAssertEqual(schedule.flush(itemCount: items.count, displayedIndex: 4, pending: false), [])
    }

    func testFlushWithoutAnEarlierDeferralReleasesNothing() {
        var schedule = GalleryReleaseSchedule()
        XCTAssertEqual(schedule.flush(itemCount: 8, displayedIndex: 4, pending: false), [])
        _ = schedule.note(itemCount: 8, index: 4, displayedIndex: 4, pending: false)
        XCTAssertEqual(schedule.flush(itemCount: 8, displayedIndex: 4, pending: false), [])
    }

    func testAnEmptyGalleryKeepsTheDeferralForTheNextFlush() {
        var schedule = GalleryReleaseSchedule()
        _ = schedule.note(itemCount: 5, index: 4, displayedIndex: 1, pending: true)
        XCTAssertEqual(schedule.flush(itemCount: 0, displayedIndex: 0, pending: false), [])
        XCTAssertTrue(schedule.isDeferred)
        XCTAssertEqual(schedule.flush(itemCount: 3, displayedIndex: 0, pending: false), [2])
    }

    func testAPageChangeWithNothingQueuedReleasesAndClearsTheDeferral() {
        var schedule = GalleryReleaseSchedule()
        _ = schedule.note(itemCount: 5, index: 4, displayedIndex: 1, pending: true)
        let decision = schedule.note(itemCount: 5, index: 4, displayedIndex: 4, pending: false)
        XCTAssertEqual(decision.indices, [0, 1, 2])
        XCTAssertFalse(schedule.isDeferred)
    }

    func testFlagsWhenTheOldRuleWouldHaveFreedTheShownPhoto() {
        var schedule = GalleryReleaseSchedule()
        XCTAssertTrue(schedule.note(itemCount: 5, index: 4, displayedIndex: 1, pending: true).oldRuleWouldReleaseDisplayed)
        XCTAssertFalse(schedule.note(itemCount: 5, index: 2, displayedIndex: 1, pending: true).oldRuleWouldReleaseDisplayed)
        XCTAssertFalse(schedule.note(itemCount: 5, index: 4, displayedIndex: 1, pending: false).oldRuleWouldReleaseDisplayed)
        XCTAssertFalse(schedule.note(itemCount: 5, index: 4, displayedIndex: nil, pending: true).oldRuleWouldReleaseDisplayed)
    }
}
