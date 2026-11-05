import Foundation
import XCTest
@testable import VP9Hardware

// The counters that say how often a sticker got a hardware decoder, and how often it did not because every session
// slot was taken. They decide whether the session cap (4 stickers with alpha) is why most stickers use libvpx.
final class VP9HardwareStatsTests: XCTestCase {
    func testOutcomesAreCounted() {
        let store = VP9HardwareStatsStore()
        store.record(.hardware)
        store.record(.hardware)
        store.record(.capReached)
        store.record(.sessionFailure)
        store.record(.ineligible)
        store.record(.ineligible)
        store.record(.ineligible)
        XCTAssertEqual(store.snapshot, VP9HardwareStats(hardwareStarts: 2, capMisses: 1, sessionFailures: 1, ineligible: 3, peakSessions: 0, resumes: 0))
    }

    func testThePeakSessionCountOnlyGrows() {
        let store = VP9HardwareStatsStore()
        store.noteActiveSessions(2)
        store.noteActiveSessions(8)
        store.noteActiveSessions(4)
        XCTAssertEqual(store.snapshot.peakSessions, 8)
    }

    func testTheSessionCounterTracksItsPeak() {
        let counter = VP9HardwareDecoding.SessionCounter()
        XCTAssertTrue(counter.acquire(2, limit: 8))
        XCTAssertTrue(counter.acquire(2, limit: 8))
        counter.release(2)
        XCTAssertFalse(counter.acquire(8, limit: 8))
        XCTAssertEqual(counter.current, 2)
        XCTAssertEqual(counter.peak, 4)
    }

    func testAReportIsDueOncePerMinuteAndOnlyWhenSomethingHappened() {
        let store = VP9HardwareStatsStore()
        XCTAssertNil(store.takeReport(now: 1000.0))
        store.record(.capReached)
        let first = store.takeReport(now: 1000.0)
        XCTAssertNotNil(first)
        XCTAssertTrue(first?.contains("capMisses=1") == true, first ?? "")
        store.record(.capReached)
        XCTAssertNil(store.takeReport(now: 1030.0), "less than a minute after the last report")
        let second = store.takeReport(now: 1060.0)
        XCTAssertTrue(second?.contains("capMisses=2") == true, second ?? "")
        XCTAssertNil(store.takeReport(now: 1200.0), "nothing new since the last report")
    }

    func testAClockGoingBackwardsDoesNotSilenceTheReport() {
        let store = VP9HardwareStatsStore()
        store.record(.hardware)
        XCTAssertNotNil(store.takeReport(now: 5000.0))
        store.record(.hardware)
        XCTAssertNotNil(store.takeReport(now: 100.0))
    }

    func testResumesAreCountedApartFromStarts() {
        let store = VP9HardwareStatsStore()
        store.record(.hardware)
        store.record(.resumed)
        store.record(.resumed)
        XCTAssertEqual(store.snapshot.hardwareStarts, 1)
        XCTAssertEqual(store.snapshot.resumes, 2)
        let report = store.takeReport(now: 1000.0)
        XCTAssertTrue(report?.contains("hardwareStarts=1") == true, report ?? "")
        XCTAssertTrue(report?.contains("resumes=2") == true, report ?? "")
    }

    func testAReportFollowsIneligibleStickers() {
        let store = VP9HardwareStatsStore()
        store.record(.ineligible)
        let report = store.takeReport(now: 1000.0)
        XCTAssertTrue(report?.contains("ineligible=1") == true, report ?? "")
    }

    func testAFullCapSkipsReadingAndParsingTheFile() {
        let limit = VP9HardwareDecoding.maxConcurrentSessions
        XCTAssertTrue(VP9HardwareDecoding.acquireSessions(limit))
        defer {
            VP9HardwareDecoding.releaseSessions(limit)
        }
        XCTAssertFalse(VP9HardwareDecoding.hasFreeSessionSlot)
        let before = VP9HardwareDecoding.stats
        var loaded = 0
        let sticker = VP9HardwareDecoding.loadSticker({
            loaded += 1
            return Data([1, 2, 3])
        })
        XCTAssertNil(sticker)
        XCTAssertEqual(loaded, 0, "the file must not be read when the cap is full")
        XCTAssertEqual(VP9HardwareDecoding.stats.capMisses - before.capMisses, 1)
    }

    func testAFreeSlotReadsTheFile() {
        XCTAssertTrue(VP9HardwareDecoding.hasFreeSessionSlot)
        let before = VP9HardwareDecoding.stats
        var loaded = 0
        // Not a WebM file: it is read, does not parse, and is not a cap miss.
        let sticker = VP9HardwareDecoding.loadSticker({
            loaded += 1
            return Data([1, 2, 3])
        })
        XCTAssertNil(sticker)
        XCTAssertEqual(loaded, 1)
        XCTAssertEqual(VP9HardwareDecoding.stats.capMisses, before.capMisses)
    }

    func testAFileThatCannotBeReadGivesNoSticker() {
        XCTAssertNil(VP9HardwareDecoding.loadSticker({ nil }))
    }

    func testOneFreeSlotIsEnoughToReadTheFile() {
        let limit = VP9HardwareDecoding.maxConcurrentSessions
        XCTAssertTrue(VP9HardwareDecoding.acquireSessions(limit - 1))
        defer {
            VP9HardwareDecoding.releaseSessions(limit - 1)
        }
        XCTAssertTrue(VP9HardwareDecoding.hasFreeSessionSlot)
    }
}
