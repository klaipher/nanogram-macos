import Foundation
import NanogramDebug
import TgVoipWebrtc

public enum CallVideoDebugOptions {
    public static let section = "Streams & Calls"

    public static let livestreamHardwareDecoding = NanogramDebugOption.toggle(id: "calls.livestreamHardwareDecoding", section: CallVideoDebugOptions.section, title: "Livestream hardware decoding", detail: "Decodes live stream video with the video chip instead of the CPU (H.264 and 8-bit HEVC, up to 2 streams) and falls back on any failure. Default: off. Applies to the next stream.", defaultValue: false)

    public static let hardwareCrop = NanogramDebugOption.toggle(id: "calls.hardwareCrop", section: CallVideoDebugOptions.section, title: "Hardware crop of camera video", detail: "Crops and scales camera video for the peer's aspect ratio on the media engine instead of the CPU. Falls back to the CPU if it fails. Default: off. Applies to the next encoder session.", defaultValue: false)

    public static let nativeDecodeFormat = NanogramDebugOption.toggle(id: "calls.nativeDecodeFormat", section: CallVideoDebugOptions.section, title: "Native decode format", detail: "The hardware decoder outputs the stream's own video-range frames with Metal compatibility, skipping a range conversion. Default: off. Applies to the next call.", defaultValue: false)

    public static let screencastHardwareEncoder = NanogramDebugOption.toggle(id: "calls.screencastHardwareEncoder", section: CallVideoDebugOptions.section, title: "Screen share hardware encoder", detail: "Encodes group-call screen shares with the video chip instead of the CPU when H.264 is negotiated. Text may look softer. Default: off. Applies to the next share.", defaultValue: false)

    public static let all: [NanogramDebugOption] = [
        CallVideoDebugOptions.livestreamHardwareDecoding,
        CallVideoDebugOptions.hardwareCrop,
        CallVideoDebugOptions.nativeDecodeFormat,
        CallVideoDebugOptions.screencastHardwareEncoder
    ]

    public static func applyNativeOptions(from settings: NanogramDebugSettings) {
        TGCallsRuntimeOptionsBridge.setHardwareCropEnabled(settings.bool(CallVideoDebugOptions.hardwareCrop.id))
        TGCallsRuntimeOptionsBridge.setNativeDecodeFormatEnabled(settings.bool(CallVideoDebugOptions.nativeDecodeFormat.id))
        TGCallsRuntimeOptionsBridge.setLivestreamHardwareDecodingEnabled(settings.bool(CallVideoDebugOptions.livestreamHardwareDecoding.id))
        TGCallsRuntimeOptionsBridge.setScreencastHardwareEncoderEnabled(settings.bool(CallVideoDebugOptions.screencastHardwareEncoder.id))
        CallAudioDebugOptions.applyNativeOptions(from: settings)
        CallSystemDebugOptions.applyNativeOptions(from: settings)
    }

    public static func migrateStoredValues(in settings: NanogramDebugSettings) {
        settings.migrate(from: "tgcalls.livestreamHardwareDecode", to: CallVideoDebugOptions.livestreamHardwareDecoding.id)
        settings.migrate(from: "tgcalls.screencastHardwareEncoder", to: CallVideoDebugOptions.screencastHardwareEncoder.id)
        settings.migrate(from: "calls.thermalLadder", to: CallSystemDebugOptions.thermalVideoLadder.id, transform: { stored in
            return (stored as? String) == "uiAndVideo" ? true : nil
        })
        for removed in ["calls.backgroundGradientIdle", "calls.cameraFormatV2", "calls.encoderLowLatency", "calls.groupVideoCap", "calls.groupNarrowbandProcessing", "calls.micGainMode", "calls.opusComplexity", "calls.apmRate", "calls.suspendHiddenLivestream"] {
            settings.migrate(from: removed, to: removed + ".removed", transform: { _ in nil })
        }
    }

    public static func install(in settings: NanogramDebugSettings = NanogramDebugSettings.shared) -> [NanogramDebugObservation] {
        CallVideoDebugOptions.migrateStoredValues(in: settings)
        let options = CallVideoDebugOptions.all + CallAudioDebugOptions.all + CallSystemDebugOptions.all
        for option in options {
            settings.register(option)
        }
        CallVideoDebugOptions.applyNativeOptions(from: settings)
        return options.map { option in
            settings.observe(option.id) { settings in
                CallVideoDebugOptions.applyNativeOptions(from: settings)
            }
        }
    }
}
