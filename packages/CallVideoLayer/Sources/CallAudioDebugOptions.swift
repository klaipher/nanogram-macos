import Foundation
import NanogramDebug
import TgVoipWebrtc

/// Debug switches for the call audio chain (macOS). Every default keeps today's behaviour; none of them changes what is
/// negotiated or sent on the wire, they only change how the local capture chain and Opus encoder spend CPU.
/// They are read when a call starts.
public enum CallAudioDebugOptions {
    public static let groupNoiseMode = NanogramDebugOption.choice(id: "calls.groupNoiseMode", section: CallVideoDebugOptions.section, title: "Group calls: noise suppressors", detail: "Both: WebRTC's suppressor and RNNoise run when noise suppression is on (today). One: only the chosen suppressor runs, which saves CPU and avoids double-processing artefacts. Applies to the next group call.", options: [
        NanogramDebugChoice(id: "both", title: "Both (default)"),
        NanogramDebugChoice(id: "apm", title: "WebRTC suppressor only"),
        NanogramDebugChoice(id: "rnnoise", title: "RNNoise only")
    ], defaultValue: "both")

    public static let micGainMode = NanogramDebugOption.choice(id: "calls.micGainMode", section: CallVideoDebugOptions.section, title: "Microphone level control", detail: "Analog: WebRTC moves the system microphone slider (today). Digital: the level is evened out in software and the system slider stays put. Applies to the next call.", options: [
        NanogramDebugChoice(id: "analog", title: "Analog (default)"),
        NanogramDebugChoice(id: "digital", title: "Digital, system slider untouched")
    ], defaultValue: "analog")

    public static let opusComplexity = NanogramDebugOption.choice(id: "calls.opusComplexity", section: CallVideoDebugOptions.section, title: "Opus encoder complexity", detail: "Lower complexity uses less CPU to encode your voice; the other side decodes it the same way. Default is the encoder's own setting (9). Applies to the next call.", options: [
        NanogramDebugChoice(id: "default", title: "Default (9)"),
        NanogramDebugChoice(id: "7", title: "7"),
        NanogramDebugChoice(id: "5", title: "5")
    ], defaultValue: "default")

    public static let apmRate = NanogramDebugOption.toggle(id: "calls.apmRate", section: CallVideoDebugOptions.section, title: "Voice processing at 32 kHz", detail: "Runs echo cancellation and noise suppression at 32 kHz instead of 48 kHz when the voice bitrate is 40 kbps or lower. Slightly less CPU. Applies to the next call.", defaultValue: false)

    public static let audioWorkgroup = NanogramDebugOption.toggle(id: "calls.audioWorkgroup", section: CallVideoDebugOptions.section, title: "Audio threads join the device's real-time workgroup", detail: "The microphone and speaker worker threads join the audio device's workgroup so the system schedules them with the audio hardware. Falls back to normal scheduling if the device has none. Applies to the next call.", defaultValue: false)

    public static let all: [NanogramDebugOption] = [
        CallAudioDebugOptions.groupNoiseMode,
        CallAudioDebugOptions.micGainMode,
        CallAudioDebugOptions.opusComplexity,
        CallAudioDebugOptions.apmRate,
        CallAudioDebugOptions.audioWorkgroup
    ]

    public static func groupNoiseModeValue(_ choice: String?) -> Int {
        switch choice {
        case "apm": return 1
        case "rnnoise": return 2
        default: return 0
        }
    }

    public static func micGainModeValue(_ choice: String?) -> Int {
        return choice == "digital" ? 1 : 0
    }

    public static func opusComplexityValue(_ choice: String?) -> Int {
        guard let choice = choice, let value = Int(choice), value >= 5, value <= 10 else {
            return 0
        }
        return value
    }

    public static func applyNativeOptions(from settings: NanogramDebugSettings) {
        TGCallsRuntimeOptionsBridge.setGroupNoiseMode(CallAudioDebugOptions.groupNoiseModeValue(settings.choice(CallAudioDebugOptions.groupNoiseMode.id)))
        TGCallsRuntimeOptionsBridge.setMicGainMode(CallAudioDebugOptions.micGainModeValue(settings.choice(CallAudioDebugOptions.micGainMode.id)))
        TGCallsRuntimeOptionsBridge.setOpusComplexity(CallAudioDebugOptions.opusComplexityValue(settings.choice(CallAudioDebugOptions.opusComplexity.id)))
        TGCallsRuntimeOptionsBridge.setLowBitrateApmRateEnabled(settings.bool(CallAudioDebugOptions.apmRate.id))
        TGCallsRuntimeOptionsBridge.setAudioWorkgroupEnabled(settings.bool(CallAudioDebugOptions.audioWorkgroup.id))
    }
}
