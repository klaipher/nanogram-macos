import XCTest
import NanogramDebug
@testable import NanogramRuntime

final class LinkHygieneTests: XCTestCase {
    func testStripsUtmAndClickIds() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/a?utm_source=x&id=7&fbclid=abc&utm_medium=y"), "https://example.com/a?id=7")
    }

    func testRemovesQuestionMarkWhenNothingRemains() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/a?utm_source=x&gclid=1"), "https://example.com/a")
    }

    func testKeepsFragmentAndOrder() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/p?b=2&igshid=z&a=1#top"), "https://example.com/p?b=2&a=1#top")
    }

    func testNamesAreCaseInsensitive() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/?UTM_Source=x&Gclid=1&q=a"), "https://example.com/?q=a")
    }

    func testLeavesMeaningfulParametersAlone() {
        let link = "https://example.com/search?q=utm&page=2&t=30"
        XCTAssertEqual(LinkHygiene.strippingTracking(link), link)
    }

    func testHostSpecificParameters() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://youtu.be/abc?si=xyz&t=42"), "https://youtu.be/abc?t=42")
        XCTAssertEqual(LinkHygiene.strippingTracking("https://www.youtube.com/watch?v=abc&si=xyz"), "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/watch?v=abc&si=xyz"), "https://example.com/watch?v=abc&si=xyz")
        XCTAssertEqual(LinkHygiene.strippingTracking("https://www.amazon.com/dp/B0?tag=x&pd_rd_w=1&th=1"), "https://www.amazon.com/dp/B0?th=1")
        XCTAssertEqual(LinkHygiene.strippingTracking("https://m.facebook.com/p?refsrc=a&__cft__[0]=b&id=3"), "https://m.facebook.com/p?id=3")
        XCTAssertEqual(LinkHygiene.strippingTracking("https://notyoutube.com/?si=xyz"), "https://notyoutube.com/?si=xyz")
        let kept = "https://x.com/user/status/1?s=20&t=abc"
        XCTAssertEqual(LinkHygiene.strippingTracking(kept), kept)
    }

    func testTelegramAndOtherSchemesUntouched() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://t.me/bot?start=utm_x&utm_source=a"), "https://t.me/bot?start=utm_x")
        XCTAssertEqual(LinkHygiene.strippingTracking("tg://resolve?domain=x&utm_source=a"), "tg://resolve?domain=x&utm_source=a")
        XCTAssertEqual(LinkHygiene.strippingTracking("mailto:a@b.c?utm_source=a"), "mailto:a@b.c?utm_source=a")
        XCTAssertEqual(LinkHygiene.strippingTracking("not a link"), "not a link")
    }

    func testQueryInsideFragmentIsNotTouched() {
        let link = "https://example.com/#/route?utm_source=a"
        XCTAssertEqual(LinkHygiene.strippingTracking(link), link)
    }

    func testHostWithUserInfoAndPort() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://user@example.com:8080/a?gclid=1"), "https://user@example.com:8080/a")
    }

    func testTelegramLinkDetection() {
        XCTAssertTrue(LinkHygiene.isTelegramLink("https://t.me/durov"))
        XCTAssertTrue(LinkHygiene.isTelegramLink("http://telegram.me/joinchat/abc"))
        XCTAssertTrue(LinkHygiene.isTelegramLink("tg://join?invite=abc"))
        XCTAssertTrue(LinkHygiene.isTelegramLink("  HTTPS://T.ME/x "))
        XCTAssertFalse(LinkHygiene.isTelegramLink("https://example.com/t.me"))
        XCTAssertFalse(LinkHygiene.isTelegramLink("https://nott.me/x"))
        XCTAssertFalse(LinkHygiene.isTelegramLink("@username"))
    }

    func testBothOptionsAreOffByDefaultAndUserFacing() {
        let defaults = UserDefaults(suiteName: "LinkHygieneTests.\(UUID().uuidString)")!
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(LinkHygiene.stripOption)
        settings.register(LinkHygiene.confirmOption)
        XCTAssertFalse(LinkHygiene.stripsTracking(in: settings))
        XCTAssertFalse(LinkHygiene.confirmsTelegramLinks(in: settings))
        XCTAssertTrue(LinkHygiene.stripOption.isUserFacing)
        XCTAssertTrue(LinkHygiene.confirmOption.isUserFacing)
        settings.set(LinkHygiene.stripOptionId, bool: true)
        XCTAssertTrue(LinkHygiene.stripsTracking(in: settings))
    }

    func testStandardListMatchesTheSharedDataFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/specs/link-tracking-params.txt")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("docs/specs/link-tracking-params.txt is not reachable from the test sandbox")
        }
        let file = TrackingParameterList(fileContents: contents)
        XCTAssertEqual(file.ruleCount, LinkHygiene.standardList.ruleCount)
        for sample in [("utm_x", "a.com"), ("ysclid", "a.com"), ("spm", "a.com"), ("si", "youtu.be"), ("si", "a.com"), ("pd_rd_w", "www.amazon.com"), ("__cft__[0]", "facebook.com"), ("share_id", "tiktok.com"), ("feature", "open.spotify.com"), ("s", "x.com"), ("id", "a.com")] {
            XCTAssertEqual(file.isTracking(name: sample.0, host: sample.1), LinkHygiene.standardList.isTracking(name: sample.0, host: sample.1))
        }
    }
}
