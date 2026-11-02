import XCTest
@testable import NanogramKit

final class StrictnessTests: XCTestCase {
    func test_installHooks_isIdempotent() {
        Nanogram.installHooks()
        Nanogram.installHooks()
        XCTAssertEqual(Nanogram.installedHookCount, 1)
    }
}
