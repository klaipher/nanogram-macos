import XCTest
@testable import NanogramRuntime

final class GalleryItemReleaseTests: XCTestCase {
    func testKeepsTheShownPhotoWhileAHistoryUpdateIsStillQueued() {
        let items = ["A", "B", "C", "D", "E"]
        let shown = 1
        let indexInTheQueuedList = 4
        let released = GalleryItemRelease.indicesToRelease(itemCount: items.count, around: indexInTheQueuedList, displayedIndex: shown, hasPendingChanges: true)
        XCTAssertFalse(released.contains(shown), "released \(released.map { items[$0] })")
        XCTAssertEqual(released, [])
    }

    func testReleasesAroundTheShownPhotoOnceTheQueuedUpdateIsApplied() {
        let items = ["X", "Y", "Z", "A", "B", "C", "D", "E"]
        let shown = 4
        let released = GalleryItemRelease.indicesToRelease(itemCount: items.count, around: shown, displayedIndex: shown, hasPendingChanges: false)
        XCTAssertEqual(released.map { items[$0] }, ["X", "Y", "Z", "D", "E"])
    }

    func testWithNothingQueuedReleasesEverythingMoreThanOneAway() {
        let items = ["A", "B", "C", "D", "E"]
        let released = GalleryItemRelease.indicesToRelease(itemCount: items.count, around: 4, displayedIndex: 4, hasPendingChanges: false)
        XCTAssertEqual(released.map { items[$0] }, ["A", "B", "C"])
    }

    func testNeverReleasesThePhotoOnScreenEvenWhenTheNewIndexIsFarAway() {
        let items = ["A", "B", "C", "D", "E"]
        let released = GalleryItemRelease.indicesToRelease(itemCount: items.count, around: 4, displayedIndex: 1, hasPendingChanges: false)
        XCTAssertEqual(released.map { items[$0] }, ["A", "C"])
    }

    func testEmptyGalleryReleasesNothing() {
        XCTAssertEqual(GalleryItemRelease.indicesToRelease(itemCount: 0, around: 0, displayedIndex: nil, hasPendingChanges: false), [])
    }
}
