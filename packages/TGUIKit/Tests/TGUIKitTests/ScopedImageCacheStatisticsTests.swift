import XCTest
import AppKit
@testable import TGUIKit

private final class StatsClock {
    var now: CFAbsoluteTime = 1000
}

final class ScopedImageCacheStatisticsTests: XCTestCase {
    private var clock: StatsClock!

    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
        clock = StatsClock()
    }

    private func makeCache(name: String = "test", countLimit: Int = 100, byteLimit: Int = 100 * 1024 * 1024, idleTimeout: TimeInterval = 300) -> ScopedImageCache {
        let clock = self.clock!
        return ScopedImageCache(name: name, countLimit: countLimit, byteLimit: byteLimit, idleTimeout: idleTimeout, closedScopeGrace: 15, sweepInterval: 3600, clock: { clock.now })
    }

    func testHitsAndMissesAreCounted() {
        let cache = makeCache()
        XCTAssertEqual(cache.statistics, ScopedImageCacheStatistics())
        XCTAssertNil(cache.image(forKey: 1))
        cache.setImage(testImage(CGSize(width: 4, height: 4)), sampleBuffer: nil, forKey: 1)
        XCTAssertNotNil(cache.image(forKey: 1))
        XCTAssertNotNil(cache.image(forKey: 1))
        XCTAssertNil(cache.image(forKey: 2))
        let statistics = cache.statistics
        XCTAssertEqual(statistics.hits, 2)
        XCTAssertEqual(statistics.misses, 2)
        XCTAssertEqual(statistics.stores, 1)
        XCTAssertEqual(statistics.evictions, 0)
    }

    func testCountLimitEvictionsAreCounted() {
        let cache = makeCache(countLimit: 2)
        for key in 0 ..< 5 {
            cache.setImage(testImage(CGSize(width: 4, height: 4)), sampleBuffer: nil, forKey: key)
            clock.now += 1
        }
        XCTAssertEqual(cache.statistics.stores, 5)
        XCTAssertEqual(cache.statistics.evictions, 3)
    }

    func testByteLimitEvictionsAreCounted() {
        let small = testImage(CGSize(width: 10, height: 10))
        let cache = makeCache(byteLimit: small.bytesPerRow * small.height * 2)
        for key in 0 ..< 4 {
            cache.setImage(testImage(CGSize(width: 10, height: 10)), sampleBuffer: nil, forKey: key)
            clock.now += 1
        }
        XCTAssertEqual(cache.statistics.evictions, 2)
    }

    func testIdleExpiryIsCountedAsEviction() {
        let cache = makeCache(idleTimeout: 10)
        cache.setImage(testImage(CGSize(width: 4, height: 4)), sampleBuffer: nil, forKey: 1)
        clock.now += 11
        cache.sweep()
        XCTAssertEqual(cache.statistics.evictions, 1)
        XCTAssertNil(cache.image(forKey: 1))
        XCTAssertEqual(cache.statistics.misses, 1)
    }

    func testReplacingAKeyIsNotAnEviction() {
        let cache = makeCache()
        cache.setImage(testImage(CGSize(width: 4, height: 4)), sampleBuffer: nil, forKey: 1)
        cache.setImage(testImage(CGSize(width: 4, height: 4)), sampleBuffer: nil, forKey: 1)
        XCTAssertEqual(cache.statistics.evictions, 0)
        XCTAssertEqual(cache.statistics.stores, 2)
    }

    func testRemoveAllIsCountedAsPurge() {
        let cache = makeCache()
        for key in 0 ..< 3 {
            cache.setImage(testImage(CGSize(width: 4, height: 4)), sampleBuffer: nil, forKey: key)
        }
        cache.removeAll()
        XCTAssertEqual(cache.statistics.purged, 3)
        XCTAssertEqual(cache.statistics.evictions, 0)
    }

    func testSummaryNamesTheCacheAndItsCounters() {
        let cache = makeCache(name: "photos")
        _ = cache.image(forKey: 1)
        cache.setImage(testImage(CGSize(width: 4, height: 4)), sampleBuffer: nil, forKey: 1)
        _ = cache.image(forKey: 1)
        let line = cache.statistics.summary(name: cache.name, entries: cache.count, bytes: cache.cost)
        XCTAssertTrue(line.contains("photos"))
        XCTAssertTrue(line.contains("hits=1"))
        XCTAssertTrue(line.contains("misses=1"))
        XCTAssertTrue(line.contains("evictions=0"))
        XCTAssertTrue(line.contains("entries=1"))
    }

    func testDiagnosticsSummaryListsLiveCaches() {
        let cache = makeCache(name: "diagnostics-unique-name")
        _ = cache.image(forKey: 1)
        XCTAssertTrue(ScopedImageCache.diagnosticsSummary().contains("diagnostics-unique-name"))
        withExtendedLifetime(cache) {}
    }

    func testIdentityMismatchOnTheSameKeyIsAMissAndNotTheWrongImage() {
        let cache = makeCache()
        let image = testImage(CGSize(width: 4, height: 4))
        cache.setImage(image, sampleBuffer: nil, forKey: 7, identity: AnyHashable("first"))
        XCTAssertTrue(cache.image(forKey: 7, identity: AnyHashable("first"))?.0 === image)
        XCTAssertNil(cache.image(forKey: 7, identity: AnyHashable("second")))
        let statistics = cache.statistics
        XCTAssertEqual(statistics.hits, 1)
        XCTAssertEqual(statistics.misses, 1)
        XCTAssertEqual(statistics.collisions, 1)
    }

    func testIdentitylessLookupStillMatchesAnyStoredEntry() {
        let cache = makeCache()
        let image = testImage(CGSize(width: 4, height: 4))
        cache.setImage(image, sampleBuffer: nil, forKey: 7)
        XCTAssertTrue(cache.image(forKey: 7)?.0 === image)
        XCTAssertTrue(cache.image(forKey: 7, identity: AnyHashable("x"))?.0 === image)
    }
}
