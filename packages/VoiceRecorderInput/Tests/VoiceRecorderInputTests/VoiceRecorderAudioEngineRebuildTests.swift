import AVFoundation
import CoreAudio
import XCTest
@testable import VoiceRecorderInput

final class VoiceRecorderAudioEngineRebuildTests: XCTestCase {
    func testAConfigurationChangeRebuildsTheEngineAndResolvesTheMicrophoneAgain() {
        var engines: [AVAudioEngine] = []
        var resolved: [String] = []
        let recorder = VoiceRecorderAudioEngine(inputDeviceUID: "USBMic", voiceProcessing: false, makeEngine: {
            let engine = AVAudioEngine()
            engines.append(engine)
            return engine
        }, resolveDevice: { uid in
            resolved.append(uid)
            return nil
        })
        var changes = 0
        recorder.onConfigurationChange = {
            changes += 1
        }
        recorder.configureIfNeeded()
        XCTAssertEqual(engines.count, 1)
        XCTAssertEqual(resolved, ["USBMic"])

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[0])
        XCTAssertEqual(changes, 1)

        recorder.configureIfNeeded()
        XCTAssertEqual(engines.count, 2, "a restart after the configuration change must not reuse the old engine and its dead device")
        XCTAssertEqual(resolved, ["USBMic", "USBMic"], "the chosen microphone is looked up again on the rebuilt engine")
        XCTAssertTrue(recorder.currentEngine === engines.last)

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines.last!)
        XCTAssertEqual(changes, 2, "the rebuilt engine still reports configuration changes")
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[0])
        XCTAssertEqual(changes, 2, "the old engine is no longer observed")
    }

    func testWithoutAConfigurationChangeTheEngineIsKept() {
        var engines = 0
        let recorder = VoiceRecorderAudioEngine(inputDeviceUID: nil, voiceProcessing: false, makeEngine: {
            engines += 1
            return AVAudioEngine()
        }, resolveDevice: { _ in nil })
        recorder.configureIfNeeded()
        recorder.configureIfNeeded()
        XCTAssertEqual(engines, 1)
    }
}
