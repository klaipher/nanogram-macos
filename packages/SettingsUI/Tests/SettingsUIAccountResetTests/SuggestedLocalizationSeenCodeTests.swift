import XCTest
@testable import SettingsUI

final class SuggestedLocalizationSeenCodeTests: XCTestCase {
    func testStoredCodeWinsOverTheRequestedLocale() {
        XCTAssertEqual(suggestedLocalizationSeenCode(stored: "ru", requested: "uk"), "ru")
    }

    func testRequestedCodeIsUsedWithoutAStoredEntry() {
        XCTAssertEqual(suggestedLocalizationSeenCode(stored: nil, requested: "uk"), "uk")
        XCTAssertEqual(suggestedLocalizationSeenCode(stored: "", requested: "uk"), "uk")
    }

    func testSameCodesStayTheSame() {
        XCTAssertEqual(suggestedLocalizationSeenCode(stored: "de", requested: "de"), "de")
    }
}
