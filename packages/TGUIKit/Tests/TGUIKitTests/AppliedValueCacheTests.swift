import XCTest
@testable import TGUIKit

final class AppliedValueCacheTests: XCTestCase {
    func testWritesOnlyWhenTheValueChanges() {
        var cache = AppliedValueCache<CGFloat>()
        XCTAssertTrue(cache.needsWrite(20))
        XCTAssertFalse(cache.needsWrite(20))
        XCTAssertFalse(cache.needsWrite(20))
        XCTAssertTrue(cache.needsWrite(12))
        XCTAssertFalse(cache.needsWrite(12))
    }

    func testInvalidateForcesTheNextWrite() {
        var cache = AppliedValueCache<CGFloat>()
        XCTAssertTrue(cache.needsWrite(20))
        cache.invalidate()
        XCTAssertTrue(cache.needsWrite(20))
    }
}
