import XCTest
import CoreAudio
import InAppSettings
@testable import TelegramMediaUtils

final class MicrophonePolicyTests: XCTestCase {
    private let builtIn = CaptureDeviceCandidate(uniqueID: "BuiltInMicrophoneDevice", isAvailable: true, transport: .builtIn)
    private let closedLidBuiltIn = CaptureDeviceCandidate(uniqueID: "BuiltInMicrophoneDevice", isAvailable: false, transport: .builtIn)
    private let airPods = CaptureDeviceCandidate(uniqueID: "AirPods:input", isAvailable: true, transport: .bluetooth)
    private let usb = CaptureDeviceCandidate(uniqueID: "USBMic", isAvailable: true, transport: .other)

    func testTransportFromCoreAudio() {
        XCTAssertEqual(CaptureDeviceTransport(coreAudioTransportType: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(CaptureDeviceTransport(coreAudioTransportType: kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(CaptureDeviceTransport(coreAudioTransportType: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(CaptureDeviceTransport(coreAudioTransportType: kAudioDeviceTransportTypeUSB), .other)
    }

    func testBluetoothDefaultUsesTheBuiltInMicWhenTheOptionIsOn() {
        XCTAssertEqual(DevicesContext.resolveMicrophoneId(selectedId: nil, candidates: [airPods, builtIn], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: true), builtIn.uniqueID)
    }

    func testBluetoothDefaultStaysWhenTheOptionIsOff() {
        XCTAssertEqual(DevicesContext.resolveMicrophoneId(selectedId: nil, candidates: [airPods, builtIn], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: false), airPods.uniqueID)
    }

    func testExplicitSelectionIsAlwaysHonoured() {
        XCTAssertEqual(DevicesContext.resolveMicrophoneId(selectedId: airPods.uniqueID, candidates: [airPods, builtIn], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: true), airPods.uniqueID)
        XCTAssertEqual(DevicesContext.resolveMicrophoneId(selectedId: usb.uniqueID, candidates: [airPods, builtIn, usb], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: true), usb.uniqueID)
    }

    func testWithoutAUsableBuiltInMicTheHeadsetIsUsed() {
        XCTAssertEqual(DevicesContext.resolveMicrophoneId(selectedId: nil, candidates: [airPods], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: true), airPods.uniqueID)
        XCTAssertEqual(DevicesContext.resolveMicrophoneId(selectedId: nil, candidates: [airPods, closedLidBuiltIn], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: true), airPods.uniqueID)
    }

    func testNonBluetoothDefaultIsKept() {
        XCTAssertEqual(DevicesContext.resolveMicrophoneId(selectedId: nil, candidates: [usb, builtIn], defaultId: usb.uniqueID, preferBuiltInWithBluetooth: true), usb.uniqueID)
    }

    func testUnavailableSelectionFallsBackThroughThePolicy() {
        let missingUsb = CaptureDeviceCandidate(uniqueID: "USBMic", isAvailable: false, transport: .other)
        XCTAssertEqual(DevicesContext.resolveMicrophoneId(selectedId: missingUsb.uniqueID, candidates: [airPods, builtIn, missingUsb], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: true), builtIn.uniqueID)
    }

    func testTheOptionIsOffByDefaultAndSurvivesCodingAndUpdates() throws {
        XCTAssertFalse(VoiceCallSettings.defaultSettings.builtInMicrophoneWithBluetooth)
        let enabled = VoiceCallSettings.defaultSettings.withUpdatedBuiltInMicrophoneWithBluetooth(true)
        XCTAssertTrue(enabled.withUpdatedAudioInputDeviceId("USBMic").builtInMicrophoneWithBluetooth)
        XCTAssertTrue(enabled.withUpdatedNoiseSuppression(false).builtInMicrophoneWithBluetooth)
        XCTAssertTrue(enabled.withUpdatedMode(.pushToTalk).builtInMicrophoneWithBluetooth)

        let decoded = try JSONDecoder().decode(VoiceCallSettings.self, from: JSONEncoder().encode(enabled))
        XCTAssertTrue(decoded.builtInMicrophoneWithBluetooth)
        let legacy = try JSONDecoder().decode(VoiceCallSettings.self, from: JSONEncoder().encode(VoiceCallSettings.defaultSettings))
        XCTAssertFalse(legacy.builtInMicrophoneWithBluetooth)
    }

    func testCallsAndRecordersReadThePolicyFromSettings() {
        let settings = VoiceCallSettings.defaultSettings.withUpdatedBuiltInMicrophoneWithBluetooth(true)
        XCTAssertEqual(DevicesContext.resolveMicrophoneId(settings, candidates: [airPods, builtIn], defaultId: airPods.uniqueID), builtIn.uniqueID)
        XCTAssertEqual(DevicesContext.resolveMicrophoneId(VoiceCallSettings.defaultSettings, candidates: [airPods, builtIn], defaultId: airPods.uniqueID), airPods.uniqueID)
    }
}

final class RecordingMicrophonePolicyTests: XCTestCase {
    private let builtIn = CaptureDeviceCandidate(uniqueID: "BuiltInMicrophoneDevice", isAvailable: true, transport: .builtIn)
    private let airPods = CaptureDeviceCandidate(uniqueID: "AirPods:input", isAvailable: true, transport: .bluetooth)
    private let usb = CaptureDeviceCandidate(uniqueID: "USBMic", isAvailable: true, transport: .other)

    func testWithoutAChoiceNotesFollowTheSystemDefault() {
        XCTAssertNil(DevicesContext.resolveRecordingMicrophoneId(selectedId: nil, candidates: [airPods, builtIn], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: false))
        XCTAssertNil(DevicesContext.resolveRecordingMicrophoneId(selectedId: nil, candidates: [usb, builtIn], defaultId: usb.uniqueID, preferBuiltInWithBluetooth: true))
        XCTAssertNil(DevicesContext.resolveRecordingMicrophoneId(VoiceCallSettings.defaultSettings, candidates: [airPods, builtIn], defaultId: airPods.uniqueID))
    }

    func testAnExplicitChoiceIsPinned() {
        XCTAssertEqual(DevicesContext.resolveRecordingMicrophoneId(selectedId: usb.uniqueID, candidates: [airPods, usb], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: false), usb.uniqueID)
        XCTAssertEqual(DevicesContext.resolveRecordingMicrophoneId(selectedId: airPods.uniqueID, candidates: [airPods, builtIn], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: true), airPods.uniqueID)
    }

    func testTheBuiltInRedirectIsPinned() {
        XCTAssertEqual(DevicesContext.resolveRecordingMicrophoneId(selectedId: nil, candidates: [airPods, builtIn], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: true), builtIn.uniqueID)
        let settings = VoiceCallSettings.defaultSettings.withUpdatedBuiltInMicrophoneWithBluetooth(true)
        XCTAssertEqual(DevicesContext.resolveRecordingMicrophoneId(settings, candidates: [airPods, builtIn], defaultId: airPods.uniqueID), builtIn.uniqueID)
    }

    func testAMissingChoiceFallsBackToTheSystemDefault() {
        let missingUsb = CaptureDeviceCandidate(uniqueID: "USBMic", isAvailable: false, transport: .other)
        XCTAssertNil(DevicesContext.resolveRecordingMicrophoneId(selectedId: missingUsb.uniqueID, candidates: [airPods, missingUsb], defaultId: airPods.uniqueID, preferBuiltInWithBluetooth: false))
    }
}
