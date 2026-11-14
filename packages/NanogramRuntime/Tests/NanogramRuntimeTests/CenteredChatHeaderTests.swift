import XCTest
import NanogramDebug
@testable import NanogramRuntime

final class CenteredChatHeaderTests: XCTestCase {
    private func makeSettings() -> NanogramDebugSettings {
        let suite = "CenteredChatHeaderTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(CenteredChatHeader.debugOption)
        return settings
    }

    func testOffByDefault() {
        XCTAssertFalse(CenteredChatHeader.isEnabled(in: self.makeSettings()))
    }

    func testIsListedInNanogramFeatures() {
        let settings = self.makeSettings()
        let titles = settings.sections(userFacing: true).flatMap { $0.options.map { $0.title } }
        XCTAssertTrue(titles.contains("Centered chat header"))
        XCTAssertNotNil(CenteredChatHeader.debugOption.userFootnote)
    }

    func testSwitchOnOffAndReset() {
        let settings = self.makeSettings()
        settings.set(CenteredChatHeader.optionId, bool: true)
        XCTAssertTrue(CenteredChatHeader.isEnabled(in: settings))
        settings.set(CenteredChatHeader.optionId, bool: false)
        XCTAssertFalse(CenteredChatHeader.isEnabled(in: settings))
        settings.set(CenteredChatHeader.optionId, bool: true)
        settings.resetUserFacing()
        XCTAssertFalse(CenteredChatHeader.isEnabled(in: settings))
    }

    func testObserverFiresOnChangeUntilReleased() {
        let settings = self.makeSettings()
        var calls = 0
        var observation: AnyObject? = CenteredChatHeader.observe(in: settings) { calls += 1 }
        settings.set(CenteredChatHeader.optionId, bool: true)
        XCTAssertEqual(calls, 1)
        observation = nil
        settings.set(CenteredChatHeader.optionId, bool: false)
        XCTAssertEqual(calls, 1)
        _ = observation
    }
}
