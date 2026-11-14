import XCTest
@testable import TelegramTheme

final class PhotoCacheSizingTests: XCTestCase {
    private let gigabyte: UInt64 = 1024 * 1024 * 1024
    private let megabyte = 1024 * 1024

    func testFlagOffKeepsLegacyLimits() {
        let sizing = PhotoCacheSizing.current(physicalMemory: 64 * gigabyte, flagEnabled: false)
        XCTAssertEqual(sizing.photosByteLimit, 24 * megabyte)
        XCTAssertEqual(sizing.photoThumbsByteLimit, 6 * megabyte)
        XCTAssertEqual(sizing.photosClosedScopeGrace, 15)
    }

    func testSmallMemoryClampsToTheFloor() {
        let sizing = PhotoCacheSizing.scaled(physicalMemory: 4 * gigabyte)
        XCTAssertEqual(sizing.photosByteLimit, 24 * megabyte)
        XCTAssertEqual(sizing.photoThumbsByteLimit, 6 * megabyte)
    }

    func testSixteenGigabytesGetsSixtyFourMegabytes() {
        let sizing = PhotoCacheSizing.scaled(physicalMemory: 16 * gigabyte)
        XCTAssertEqual(sizing.photosByteLimit, 64 * megabyte)
        XCTAssertEqual(sizing.photoThumbsByteLimit, 16 * megabyte)
        XCTAssertEqual(sizing.photosClosedScopeGrace, 60)
    }

    func testLargeMemoryStaysUnderTheDrawingContextCap() {
        let sizing = PhotoCacheSizing.scaled(physicalMemory: 128 * gigabyte)
        XCTAssertEqual(sizing.photosByteLimit, 96 * megabyte)
        XCTAssertEqual(sizing.photoThumbsByteLimit, 24 * megabyte)
        XCTAssertLessThan(sizing.photosByteLimit, 120 * megabyte)
    }

    func testLimitsNeverShrinkBelowLegacyAndGrowMonotonically() {
        var previous = PhotoCacheSizing.legacy
        for gb in [1, 2, 4, 8, 16, 24, 32, 64, 128, 512] as [UInt64] {
            let sizing = PhotoCacheSizing.scaled(physicalMemory: gb * gigabyte)
            XCTAssertGreaterThanOrEqual(sizing.photosByteLimit, previous.photosByteLimit)
            XCTAssertGreaterThanOrEqual(sizing.photoThumbsByteLimit, previous.photoThumbsByteLimit)
            previous = sizing
        }
    }
}
