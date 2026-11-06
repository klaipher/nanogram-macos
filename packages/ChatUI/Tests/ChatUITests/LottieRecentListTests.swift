import XCTest
@testable import TelegramMedia

final class LottieRecentListTests: XCTestCase {
    func testKeepsTheMostRecentlyUsedEntries() {
        var list = LottieRecentList<String, Int>(capacity: 2)
        XCTAssertEqual(list.use("a", 1), [])
        XCTAssertEqual(list.use("b", 2), [])
        XCTAssertEqual(list.use("c", 3), [1])
        XCTAssertFalse(list.contains("a"))
        XCTAssertTrue(list.contains("b"))
        XCTAssertTrue(list.contains("c"))
    }

    func testUsingAnEntryAgainMakesItNewest() {
        var list = LottieRecentList<String, Int>(capacity: 2)
        _ = list.use("a", 1)
        _ = list.use("b", 2)
        XCTAssertEqual(list.use("a", 1), [])
        XCTAssertEqual(list.use("c", 3), [2])
        XCTAssertEqual(list.count, 2)
    }

    func testRemoveAllReturnsEverythingOnce() {
        var list = LottieRecentList<String, Int>(capacity: 3)
        _ = list.use("a", 1)
        _ = list.use("b", 2)
        XCTAssertEqual(list.removeAll(), [1, 2])
        XCTAssertEqual(list.count, 0)
        XCTAssertEqual(list.removeAll(), [])
    }

    func testCapacityIsAtLeastOne() {
        var list = LottieRecentList<String, Int>(capacity: 0)
        XCTAssertEqual(list.use("a", 1), [])
        XCTAssertEqual(list.use("b", 2), [1])
    }
}
