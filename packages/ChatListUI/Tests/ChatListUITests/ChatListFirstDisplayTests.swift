import XCTest
@testable import ChatListUI

final class ChatListFirstDisplayTests: XCTestCase {
    func testLoadingPlaceholderIsNotReady() {
        XCTAssertFalse(ChatListReadiness.isReady(isLoading: true, hasContent: false))
    }

    func testContentIsReadyEvenWhileStillLoading() {
        XCTAssertTrue(ChatListReadiness.isReady(isLoading: true, hasContent: true))
    }

    func testDefinitivelyEmptyIsReady() {
        XCTAssertTrue(ChatListReadiness.isReady(isLoading: false, hasContent: false))
    }

    func testOnlyPlainListWaitsForBanners() {
        XCTAssertTrue(ChatListFirstDisplayPolicy.waitsForBanners(mode: .plain))
        XCTAssertFalse(ChatListFirstDisplayPolicy.waitsForBanners(mode: .filter(1)))
        XCTAssertFalse(ChatListFirstDisplayPolicy.waitsForBanners(mode: .folder(.archive)))
    }

    func testCacheKeepsMostRecentlyUsed() {
        var cache = ChatListRecentViewCache<Int, String>(capacity: 3)
        cache.put(1, "a")
        cache.put(2, "b")
        cache.put(3, "c")
        XCTAssertEqual(cache.get(1), "a")
        cache.put(4, "d")
        XCTAssertNil(cache.get(2))
        XCTAssertEqual(cache.get(1), "a")
        XCTAssertEqual(cache.get(3), "c")
        XCTAssertEqual(cache.get(4), "d")
        XCTAssertEqual(cache.count, 3)
    }

    func testCachePutReplacesExistingKey() {
        var cache = ChatListRecentViewCache<Int, String>(capacity: 2)
        cache.put(1, "a")
        cache.put(1, "b")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.get(1), "b")
    }

    func testCacheClearsUnderPressure() {
        var cache = ChatListRecentViewCache<Int, String>(capacity: 3)
        cache.put(1, "a")
        cache.removeAll()
        XCTAssertNil(cache.get(1))
        XCTAssertEqual(cache.count, 0)
    }
}
