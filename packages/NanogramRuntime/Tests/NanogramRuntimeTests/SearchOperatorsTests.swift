import XCTest
import NanogramDebug
@testable import NanogramRuntime

final class SearchOperatorsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_731_585_600)

    private func parse(_ text: String) -> SearchOperatorQuery {
        return SearchOperators.parse(text, now: self.now, calendar: self.calendar)
    }

    func testPlainTextIsUntouched() {
        let query = parse("  hello   world ")
        XCTAssertEqual(query, SearchOperatorQuery(text: "  hello   world "))
    }

    func testFromUsernameAndRemainingText() {
        let query = parse("invoice from:@some_user april")
        XCTAssertEqual(query.sender, .username("some_user"))
        XCTAssertEqual(query.text, "invoice april")
        XCTAssertTrue(query.hasOperators)
    }

    func testFromNumericId() {
        XCTAssertEqual(parse("from:12345").sender, .userId(12345))
    }

    func testInvalidFromStaysText() {
        let query = parse("from:ab from:@ from:9x")
        XCTAssertNil(query.sender)
        XCTAssertFalse(query.hasOperators)
        XCTAssertEqual(query.text, "from:ab from:@ from:9x")
    }

    func testTypeNamesAndAliases() {
        XCTAssertEqual(parse("type:photo").type, .photo)
        XCTAssertEqual(parse("TYPE:Audio").type, .music)
        XCTAssertEqual(parse("type:circle").type, .round)
        XCTAssertEqual(parse("type:links").type, .link)
        XCTAssertNil(parse("type:banana").type)
        XCTAssertEqual(parse("type:banana").text, "type:banana")
    }

    func testDateTodayAndYesterday() {
        let today = parse("date:today")
        XCTAssertEqual(today.minDate, 1_731_542_400)
        XCTAssertEqual(today.maxDate, 1_731_628_799)
        XCTAssertEqual(parse("date:yesterday").minDate, 1_731_456_000)
    }

    func testAfterIsInclusiveAndBeforeIsExclusive() {
        let query = parse("after:2024-11-01 before:2024-11-10")
        XCTAssertEqual(query.minDate, 1_730_419_200)
        XCTAssertEqual(query.maxDate, 1_731_196_800 - 1)
        XCTAssertEqual(query.text, "")
    }

    func testDateIntersectsWithAfterAndBefore() {
        let query = parse("date:2024-11-05 after:2024-11-06")
        XCTAssertEqual(query.minDate, 1_730_937_600)
        XCTAssertEqual(query.maxDate, 1_730_937_599)
        XCTAssertTrue(query.isEmptyRange)
    }

    func testInvalidDatesStayText() {
        XCTAssertEqual(parse("after:2024-13-01").text, "after:2024-13-01")
        XCTAssertEqual(parse("before:2024-02-30").text, "before:2024-02-30")
        XCTAssertEqual(parse("date:11/05/2024").text, "date:11/05/2024")
        XCTAssertEqual(parse("after:2200-01-01").text, "after:2200-01-01")
    }

    func testLastOperatorWins() {
        let query = parse("type:photo type:video from:first_user from:@second_user")
        XCTAssertEqual(query.type, .video)
        XCTAssertEqual(query.sender, .username("second_user"))
    }

    func testUrlsAndUnknownKeysStayText() {
        let query = parse("see https://example.com/a?b=c note:todo type:gif")
        XCTAssertEqual(query.text, "see https://example.com/a?b=c note:todo")
        XCTAssertEqual(query.type, .gif)
    }

    func testOptionIsOnByDefaultAndUserFacing() {
        let defaults = UserDefaults(suiteName: "SearchOperatorsTests.\(UUID().uuidString)")!
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(SearchOperators.debugOption)
        XCTAssertTrue(SearchOperators.isEnabled(in: settings))
        XCTAssertTrue(SearchOperators.debugOption.isUserFacing)
        settings.set(SearchOperators.optionId, bool: false)
        XCTAssertFalse(SearchOperators.isEnabled(in: settings))
    }
}
