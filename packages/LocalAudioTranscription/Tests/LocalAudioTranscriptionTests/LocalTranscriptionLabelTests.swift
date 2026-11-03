import XCTest
import NanogramDebug
@testable import LocalAudioTranscription

final class LocalTranscriptionLabelTests: XCTestCase {
    private func settings() -> (NanogramDebugSettings, () -> Void) {
        let suite = "LocalTranscriptionLabelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (NanogramDebugSettings(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    func testDebugSwitchIsOnByDefaultWithoutRegistration() {
        let (settings, cleanup) = self.settings()
        defer { cleanup() }
        XCTAssertEqual(LocalAudioTranscription.debugOption.section, "Voice")
        guard case let .toggle(defaultValue) = LocalAudioTranscription.debugOption.kind else {
            return XCTFail("toggle expected")
        }
        XCTAssertTrue(defaultValue)
        XCTAssertTrue(LocalAudioTranscription.isEnabled(in: settings))
        settings.register(LocalAudioTranscription.debugOption)
        XCTAssertTrue(LocalAudioTranscription.isEnabled(in: settings))
    }

    func testDebugSwitchTurnsTheLocalEngineOff() {
        let (settings, cleanup) = self.settings()
        defer { cleanup() }
        settings.register(LocalAudioTranscription.debugOption)
        settings.set(LocalAudioTranscription.debugOption.id, bool: false)
        XCTAssertFalse(LocalAudioTranscription.isEnabled(in: settings))
        XCTAssertFalse(LocalAudioTranscription.shouldTranscribeLocally(isEnabled: LocalAudioTranscription.isEnabled(in: settings), isPremium: false, isVoice: true, hasServerTranscription: false))
        settings.reset(LocalAudioTranscription.debugOption.id)
        XCTAssertTrue(LocalAudioTranscription.isEnabled(in: settings))
    }

    func testOnlyFinishedLocalResultsAreMarkedOnDevice() {
        XCTAssertTrue(LocalAudioTranscription.isOnDevice(transcriptionId: 0, isPending: false))
        XCTAssertFalse(LocalAudioTranscription.isOnDevice(transcriptionId: 0, isPending: true))
        XCTAssertFalse(LocalAudioTranscription.isOnDevice(transcriptionId: 5_123_456_789, isPending: false))
    }
}
