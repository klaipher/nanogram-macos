import XCTest
import NanogramDebug
@testable import NanogramRuntime

// The vectors are the ones in the shared grammar (docs/specs/search-operators.md in the iOS repo).
final class SearchOperatorsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func seconds(_ y: Int, _ m: Int, _ d: Int) -> Int32 {
        let date = self.calendar.date(from: DateComponents(year: y, month: m, day: d))!
        return Int32(date.timeIntervalSince1970)
    }

    private var now: Date {
        return self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!
    }

    private func parse(_ query: String) -> SearchOperatorQuery {
        return SearchOperators.parse(query, now: self.now, calendar: self.calendar)
    }

    func testPlainTextIsUntouched() {
        XCTAssertEqual(self.parse("  hello   world "), SearchOperatorQuery(text: "  hello   world "))
        XCTAssertFalse(self.parse("hello").hasOperators)
    }

    func testFromWithAndWithoutAt() {
        XCTAssertEqual(self.parse("hello from:@jane").fromName, "jane")
        XCTAssertEqual(self.parse("hello from:@jane").text, "hello")
        XCTAssertEqual(self.parse("from:jane").fromName, "jane")
    }

    func testFromMe() {
        XCTAssertTrue(self.parse("from:me hi").isMe)
        XCTAssertTrue(self.parse("FROM:Me").isMe)
        XCTAssertNil(self.parse("from:me").resolvableUsername)
    }

    func testFromInQuotesKeepsSpaces() {
        let result = self.parse("from:\"Jane Doe\" x")
        XCTAssertEqual(result.fromName, "Jane Doe")
        XCTAssertEqual(result.text, "x")
        XCTAssertNil(result.resolvableUsername)
    }

    func testResolvableUsernameShape() {
        XCTAssertEqual(self.parse("from:@some_user").resolvableUsername, "some_user")
        XCTAssertNil(self.parse("from:ab").resolvableUsername)
        XCTAssertNil(self.parse("from:12345").resolvableUsername)
        XCTAssertNil(self.parse("from:9abcdef").resolvableUsername)
    }

    func testUnclosedQuoteStaysPlain() {
        let result = self.parse("from:\"Jane")
        XCTAssertNil(result.fromName)
        XCTAssertEqual(result.text, "from:\"Jane")
        let two = self.parse("from:\"Jane Doe")
        XCTAssertNil(two.fromName)
        XCTAssertEqual(two.text, "from:\"Jane Doe")
    }

    func testEmptyValuesStayPlain() {
        XCTAssertEqual(self.parse("from:").text, "from:")
        XCTAssertEqual(self.parse("from:@").text, "from:@")
        XCTAssertEqual(self.parse("type:").text, "type:")
    }

    func testBefore() {
        let result = self.parse("before:2026-11-01")
        XCTAssertEqual(result.maxDate, self.seconds(2026, 11, 1))
        XCTAssertNil(result.minDate)
        XCTAssertEqual(result.text, "")
    }

    func testAfterStartsOnTheNextDay() {
        XCTAssertEqual(self.parse("after:2026-11-01").minDate, self.seconds(2026, 11, 2))
    }

    func testDateIsTheWholeDay() {
        let result = self.parse("date:2026-11-01")
        XCTAssertEqual(result.minDate, self.seconds(2026, 11, 1))
        XCTAssertEqual(result.maxDate, self.seconds(2026, 11, 2))
    }

    func testMonthAndYearRanges() {
        let month = self.parse("date:2026-11")
        XCTAssertEqual(month.minDate, self.seconds(2026, 11, 1))
        XCTAssertEqual(month.maxDate, self.seconds(2026, 12, 1))
        XCTAssertEqual(self.parse("before:2026-11").maxDate, self.seconds(2026, 11, 1))
        XCTAssertEqual(self.parse("after:2026-11").minDate, self.seconds(2026, 12, 1))
        let year = self.parse("date:2026")
        XCTAssertEqual(year.minDate, self.seconds(2026, 1, 1))
        XCTAssertEqual(year.maxDate, self.seconds(2027, 1, 1))
    }

    func testTodayAndYesterday() {
        let today = self.parse("date:today")
        XCTAssertEqual(today.minDate, self.seconds(2026, 11, 14))
        XCTAssertEqual(today.maxDate, self.seconds(2026, 11, 15))
        let yesterday = self.parse("date:yesterday report")
        XCTAssertEqual(yesterday.minDate, self.seconds(2026, 11, 13))
        XCTAssertEqual(yesterday.maxDate, self.seconds(2026, 11, 14))
        XCTAssertEqual(yesterday.text, "report")
    }

    func testBadDatesStayPlain() {
        for bad in ["date:2026-02-30", "date:2026-13", "date:26-11-01", "date:2026-1-1", "date:abc", "before:1969-01-01", "after:2026-11-1x", "after:2200-01-01", "date:11/05/2024"] {
            let result = self.parse(bad)
            XCTAssertEqual(result.text, bad)
            XCTAssertNil(result.minDate)
            XCTAssertNil(result.maxDate)
        }
    }

    func testTypes() {
        XCTAssertEqual(self.parse("type:photo cat").type, .photo)
        XCTAssertEqual(self.parse("type:photo cat").text, "cat")
        XCTAssertEqual(self.parse("TYPE:Photo").type, .photo)
        XCTAssertEqual(self.parse("type:round").type, .round)
        XCTAssertEqual(self.parse("type:pinned").type, .pinned)
    }

    func testUnknownTypeStaysPlain() {
        let result = self.parse("type:banana")
        XCTAssertNil(result.type)
        XCTAssertEqual(result.text, "type:banana")
        XCTAssertEqual(self.parse("type:geo").text, "type:geo")
    }

    func testLastRepeatedOperatorWins() {
        let result = self.parse("before:2026-11-01 before:2026-10-01")
        XCTAssertEqual(result.maxDate, self.seconds(2026, 10, 1))
        XCTAssertEqual(result.text, "")
        let query = self.parse("type:photo type:video from:first_user from:@second_user")
        XCTAssertEqual(query.type, .video)
        XCTAssertEqual(query.fromName, "second_user")
    }

    func testDateCombinedWithBeforeTakesTheTighterBound() {
        let result = self.parse("date:2026-11 before:2026-11-10")
        XCTAssertEqual(result.minDate, self.seconds(2026, 11, 1))
        XCTAssertEqual(result.maxDate, self.seconds(2026, 11, 10))
        XCTAssertEqual(self.parse("date:2026-11-05 before:2026-12-01").maxDate, self.seconds(2026, 11, 6))
    }

    func testDateIntersectsWithAfterAndBefore() {
        let query = self.parse("date:2024-11-05 after:2024-11-06")
        XCTAssertEqual(query.minDate, self.seconds(2024, 11, 7))
        XCTAssertEqual(query.maxDate, self.seconds(2024, 11, 6))
        XCTAssertTrue(query.isEmptyRange)
        XCTAssertFalse(self.parse("date:2024-11-05").isEmptyRange)
    }

    func testUrlsAndUnknownNamesStayPlain() {
        XCTAssertEqual(self.parse("https://x.test/a:b").text, "https://x.test/a:b")
        XCTAssertEqual(self.parse("note:todo").text, "note:todo")
        XCTAssertEqual(self.parse("see https://example.com/a?b=c note:todo type:gif").text, "see https://example.com/a?b=c note:todo")
    }

    func testOrderOfPlainWordsIsKept() {
        XCTAssertEqual(self.parse("a type:gif b from:x c").text, "a b c")
    }

    func testRestoringAnUnresolvedFrom() {
        XCTAssertEqual(self.parse("hello from:@nobody").textRestoringFrom(), "hello from:@nobody")
        XCTAssertEqual(self.parse("from:\"A B\"").textRestoringFrom(), "from:\"A B\"")
    }

    func testOnlyOperatorsLeavesEmptyText() {
        let result = self.parse("from:@jane type:photo")
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.hasOperators)
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
