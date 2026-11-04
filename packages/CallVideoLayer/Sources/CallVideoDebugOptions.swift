import Foundation
import NanogramDebug
import TgVoipWebrtc

public enum CallVideoDebugOptions {
    public static let section = "Calls"

    public static let backgroundGradientIdle = NanogramDebugOption.toggle(id: "calls.backgroundGradientIdle", section: CallVideoDebugOptions.section, title: "Pause the call background while video is shown", detail: "The animated gradient and its blur pass stop while a video covers the call window, and in energy saving. Off: the background always animates.", defaultValue: true)

    public static let cameraFormatV2 = NanogramDebugOption.toggle(id: "calls.cameraFormatV2", section: CallVideoDebugOptions.section, title: "Camera: pick a 720p format, cap capture at 25 fps", detail: "Chooses the smallest 720p or larger non-HDR format, caps capture at the 25 fps the engine sends (the camera may still slow down in low light) and starts the camera off the main thread. Off: the previous selection. Applies to the next camera start.", defaultValue: true)

    public static let hardwareCrop = NanogramDebugOption.toggle(id: "calls.hardwareCrop", section: CallVideoDebugOptions.section, title: "Crop and scale camera video on the media engine", detail: "When the peer's aspect ratio differs, crops and scales before encoding with VideoToolbox instead of on the CPU. Falls back to the CPU path if it fails.", defaultValue: false)

    public static let nativeDecodeFormat = NanogramDebugOption.toggle(id: "calls.nativeDecodeFormat", section: CallVideoDebugOptions.section, title: "Decode call video to native video-range NV12", detail: "The hardware decoder outputs video-range frames with Metal compatibility, skipping a range conversion. Applies to the next call.", defaultValue: false)

    public static let livestreamHardwareDecode = NanogramDebugOption.toggle(id: "tgcalls.livestreamHardwareDecode", section: CallVideoDebugOptions.section, title: "Livestream: hardware video decode", detail: "Decodes live stream video with VideoToolbox (H.264 and 8-bit HEVC, up to 2 streams) and falls back to software on any failure. Applies to the next stream.", defaultValue: false)

    public static let screencastHardwareEncoder = NanogramDebugOption.toggle(id: "tgcalls.screencastHardwareEncoder", section: CallVideoDebugOptions.section, title: "Group screen share: hardware H.264 encoder", detail: "Experiment: encodes group-call screen shares with VideoToolbox instead of OpenH264 when H.264 is negotiated. Text may look softer. Applies to the next share.", defaultValue: false)

    public static let groupVideoCap = NanogramDebugOption.toggle(id: "calls.groupVideoCap", section: CallVideoDebugOptions.section, title: "Group calls: ask for at most 10 remote videos", detail: "Experiment: requests video for 10 remote channels at most, dominant speakers and screen shares first. Participants after the 10th get no video even when their tile is on screen. Off: every video participant is requested, as before.", defaultValue: false)

    public static let all: [NanogramDebugOption] = [
        CallVideoDebugOptions.groupVideoCap,
        CallVideoDebugOptions.backgroundGradientIdle,
        CallVideoDebugOptions.cameraFormatV2,
        CallVideoDebugOptions.hardwareCrop,
        CallVideoDebugOptions.nativeDecodeFormat,
        CallVideoDebugOptions.livestreamHardwareDecode,
        CallVideoDebugOptions.screencastHardwareEncoder
    ]

    public static func isBackgroundGradientIdleEnabled(in settings: NanogramDebugSettings = NanogramDebugSettings.shared) -> Bool {
        return settings.bool(CallVideoDebugOptions.backgroundGradientIdle.id)
    }

    public static func isGroupVideoCapEnabled(in settings: NanogramDebugSettings = NanogramDebugSettings.shared) -> Bool {
        return settings.bool(CallVideoDebugOptions.groupVideoCap.id)
    }

    public static func applyNativeOptions(from settings: NanogramDebugSettings) {
        TGCallsRuntimeOptionsBridge.setCameraFormatV2Enabled(settings.bool(CallVideoDebugOptions.cameraFormatV2.id))
        TGCallsRuntimeOptionsBridge.setHardwareCropEnabled(settings.bool(CallVideoDebugOptions.hardwareCrop.id))
        TGCallsRuntimeOptionsBridge.setNativeDecodeFormatEnabled(settings.bool(CallVideoDebugOptions.nativeDecodeFormat.id))
        TGCallsRuntimeOptionsBridge.setLivestreamHardwareDecodeEnabled(settings.bool(CallVideoDebugOptions.livestreamHardwareDecode.id))
        TGCallsRuntimeOptionsBridge.setScreencastHardwareEncoderEnabled(settings.bool(CallVideoDebugOptions.screencastHardwareEncoder.id))
        CallAudioDebugOptions.applyNativeOptions(from: settings)
        CallSystemDebugOptions.applyNativeOptions(from: settings)
    }

    public static func install(in settings: NanogramDebugSettings = NanogramDebugSettings.shared) -> [NanogramDebugObservation] {
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
