import XCTest
@testable import HTMLBubbles

final class MessageWidgetsSwitchTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "MessageWidgetsSwitchTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite) ?? .standard, suite)
    }

    func testKeyMatchesIOS() {
        XCTAssertEqual(MessageWidgetsSwitch.defaultsKey, "nanogram.messageWidgets.enabled.2")
    }

    func testDefaultIsOff() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(MessageWidgetsSwitch.isEnabled(in: defaults))
    }

    func testRoundTrip() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        MessageWidgetsSwitch.setEnabled(true, in: defaults)
        XCTAssertTrue(MessageWidgetsSwitch.isEnabled(in: defaults))
        XCTAssertTrue(defaults.bool(forKey: "nanogram.messageWidgets.enabled.2"))
        MessageWidgetsSwitch.setEnabled(false, in: defaults)
        XCTAssertFalse(MessageWidgetsSwitch.isEnabled(in: defaults))
    }

    func testOffAlwaysUsesUpstreamRow() {
        for media in [false, true] {
            for local in [false, true] {
                for document in [false, true] {
                    XCTAssertEqual(MessageWidgetPolicy.rowKind(hasWidgetMedia: media, hasLocalBubbleAttribute: local, hasBotDocument: document, enabled: false), .upstream)
                }
            }
        }
    }

    func testOnKeepsUpstreamOrder() {
        XCTAssertEqual(MessageWidgetPolicy.rowKind(hasWidgetMedia: true, hasLocalBubbleAttribute: true, hasBotDocument: true, enabled: true), .widget)
        XCTAssertEqual(MessageWidgetPolicy.rowKind(hasWidgetMedia: false, hasLocalBubbleAttribute: true, hasBotDocument: true, enabled: true), .localBubble)
        XCTAssertEqual(MessageWidgetPolicy.rowKind(hasWidgetMedia: false, hasLocalBubbleAttribute: false, hasBotDocument: true, enabled: true), .botDocument)
        XCTAssertEqual(MessageWidgetPolicy.rowKind(hasWidgetMedia: false, hasLocalBubbleAttribute: false, hasBotDocument: false, enabled: true), .upstream)
    }

    func testDemoEntryNeedsSwitchAndServer() {
        XCTAssertFalse(MessageWidgetPolicy.allowsDemoEntry(enabled: false, serverAllowsDemo: true))
        XCTAssertFalse(MessageWidgetPolicy.allowsDemoEntry(enabled: true, serverAllowsDemo: false))
        XCTAssertTrue(MessageWidgetPolicy.allowsDemoEntry(enabled: true, serverAllowsDemo: true))
    }

    func testEngineServiceName() {
        XCTAssertEqual(MessageWidgetPolicy.engineServiceName(embedded: "a.b", fallback: "x"), "a.b")
        XCTAssertEqual(MessageWidgetPolicy.engineServiceName(embedded: nil, fallback: "x"), "x")
        XCTAssertEqual(MessageWidgetPolicy.engineServiceName(embedded: "", fallback: "x"), "x")
        XCTAssertEqual(MessageWidgetPolicy.engineServiceFallbackName, "org.klaipher.Nanogram.WidgetEngine")
    }
}
