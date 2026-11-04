import XCTest
import NanogramDebug
@testable import CallVideoLayer

final class CallAudioDebugOptionsTests: XCTestCase {
    private func makeSettings() -> NanogramDebugSettings {
        let suite = "CallAudioDebugOptionsTests.\(UUID().uuidString)"
        return NanogramDebugSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    func testIdsAreUniqueAndDoNotClashWithVideo() {
        let ids = (CallAudioDebugOptions.all + CallVideoDebugOptions.all).map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count)
        for option in CallAudioDebugOptions.all {
            XCTAssertTrue(option.id.hasPrefix("calls."), option.id)
            XCTAssertEqual(option.section, CallVideoDebugOptions.section)
        }
    }

    func testEveryDefaultKeepsToday() {
        let settings = self.makeSettings()
        _ = CallVideoDebugOptions.install(in: settings)
        XCTAssertEqual(settings.choice("calls.groupNoiseMode"), "both")
        XCTAssertFalse(settings.bool("calls.audioWorkgroup"))
    }

    func testChoiceMapping() {
        XCTAssertEqual(CallAudioDebugOptions.groupNoiseModeValue("both"), 0)
        XCTAssertEqual(CallAudioDebugOptions.groupNoiseModeValue("apm"), 1)
        XCTAssertEqual(CallAudioDebugOptions.groupNoiseModeValue("rnnoise"), 2)
        XCTAssertEqual(CallAudioDebugOptions.groupNoiseModeValue("garbage"), 0)
        XCTAssertEqual(CallAudioDebugOptions.groupNoiseModeValue(nil), 0)
    }

    func testChoicesAreOfferedAndDefaultsExist() {
        for option in CallAudioDebugOptions.all {
            if case let .choice(options, defaultValue) = option.kind {
                XCTAssertTrue(options.contains(where: { $0.id == defaultValue }), option.id)
            }
        }
    }

    func testOverrideReachesSettings() {
        let settings = self.makeSettings()
        let observations = CallVideoDebugOptions.install(in: settings)
        settings.set("calls.groupNoiseMode", choice: "rnnoise")
        XCTAssertEqual(settings.choice("calls.groupNoiseMode"), "rnnoise")
        withExtendedLifetime(observations) {}
    }
}
