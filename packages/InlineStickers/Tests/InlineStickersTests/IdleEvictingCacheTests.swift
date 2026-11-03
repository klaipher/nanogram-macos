import XCTest
@testable import InlineStickers

private final class Entry {
    var isBusy: Bool
    init(isBusy: Bool = false) {
        self.isBusy = isBusy
    }
}

final class IdleEvictingCacheTests: XCTestCase {
    private func makeCache(limit: Int) -> IdleEvictingCache<Int, Entry> {
        return IdleEvictingCache(limit: limit, isIdle: { !$0.isBusy })
    }

    func testIdleEntriesAreCappedOldestFirst() {
        let cache = makeCache(limit: 100)
        for key in 0 ..< 10_000 {
            cache.insert(Entry(), forKey: key)
        }
        XCTAssertLessThanOrEqual(cache.count, 100)
        XCTAssertNotNil(cache[9_999])
        XCTAssertNil(cache[0])
    }

    func testRecentlyUsedEntriesSurviveTrimming() {
        let cache = makeCache(limit: 100)
        for key in 0 ..< 100 {
            cache.insert(Entry(), forKey: key)
        }
        for key in 100 ..< 1_000 {
            cache.touch(0)
            cache.insert(Entry(), forKey: key)
        }
        XCTAssertNotNil(cache[0])
        XCTAssertNil(cache[1])
    }

    func testBusyEntriesAreNeverEvicted() {
        let cache = makeCache(limit: 10)
        let busy = (0 ..< 50).map { _ in Entry(isBusy: true) }
        for (key, entry) in busy.enumerated() {
            cache.insert(entry, forKey: key)
        }
        for key in 50 ..< 500 {
            cache.insert(Entry(), forKey: key)
        }
        for (key, entry) in busy.enumerated() {
            XCTAssertTrue(cache[key] === entry)
        }
        XCTAssertLessThanOrEqual(cache.count, 50 + 10)
    }

    func testPurgingIdleKeepsOnlyBusyEntries() {
        let cache = makeCache(limit: 2048)
        let busy = Entry(isBusy: true)
        cache.insert(busy, forKey: -1)
        for key in 0 ..< 1_000 {
            cache.insert(Entry(), forKey: key)
        }
        cache.purgeIdle()
        XCTAssertEqual(cache.count, 1)
        XCTAssertTrue(cache[-1] === busy)
    }

    func testAnEntryThatBecomesIdleCanBeEvicted() {
        let cache = makeCache(limit: 2048)
        let entry = Entry(isBusy: true)
        cache.insert(entry, forKey: 1)
        cache.purgeIdle()
        XCTAssertTrue(cache[1] === entry)
        entry.isBusy = false
        cache.purgeIdle()
        XCTAssertNil(cache[1])
    }

    func testRemovingAnEntryForgetsIt() {
        let cache = makeCache(limit: 2048)
        cache.insert(Entry(), forKey: 1)
        cache.removeValue(forKey: 1)
        XCTAssertNil(cache[1])
        XCTAssertEqual(cache.count, 0)
    }
}
