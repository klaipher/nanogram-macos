import XCTest
@testable import TelegramContext

final class AppConfigValueParsingTests: XCTestCase {
    func testStarRefPrefixesAreAnArrayWithTgrDefault() {
        XCTAssertEqual(AppConfigValueParsing.stringList(["_tgr_", "_x_"] as [Any]), ["_tgr_", "_x_"])
        XCTAssertEqual(AppConfigValueParsing.stringList("_tgr_"), ["_tgr_"])
        XCTAssertNil(AppConfigValueParsing.stringList(5.0))
        XCTAssertNil(AppConfigValueParsing.stringList(nil))
    }

    func testStarRefReferrer() {
        XCTAssertEqual(AppConfigValueParsing.starRefReferrer(startParameter: "_tgr_abc", prefixes: nil), "abc")
        XCTAssertNil(AppConfigValueParsing.starRefReferrer(startParameter: "_tgref_abc", prefixes: nil))
        XCTAssertEqual(AppConfigValueParsing.starRefReferrer(startParameter: "_x_abc", prefixes: ["_tgr_", "_x_"]), "abc")
        XCTAssertNil(AppConfigValueParsing.starRefReferrer(startParameter: "plain", prefixes: ["_tgr_"]))
        XCTAssertNil(AppConfigValueParsing.starRefReferrer(startParameter: "abc", prefixes: [""]))
    }

    func testInt32AcceptsServerNumbers() {
        XCTAssertEqual(AppConfigValueParsing.int32(100.0), 100)
        XCTAssertEqual(AppConfigValueParsing.int32(100), 100)
        XCTAssertEqual(AppConfigValueParsing.int32("100"), 100)
        XCTAssertNil(AppConfigValueParsing.int32("many"))
        XCTAssertNil(AppConfigValueParsing.int32(Double.nan))
        XCTAssertNil(AppConfigValueParsing.int32(1e12))
        XCTAssertNil(AppConfigValueParsing.int32(nil))
    }
}
