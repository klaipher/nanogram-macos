import Foundation
import NanogramDebug
import TgVoipWebrtc

public enum CallSystemDebugOptions {
    public static let thermalVideoLadder = NanogramDebugOption.toggle(id: "calls.thermalVideoLadder", section: CallVideoDebugOptions.section, title: "Thermal video limits", detail: "When the Mac runs hot, your outgoing camera video gets smaller and slower (540p at 20 fps serious, 360p at 15 fps critical). Dimming and slower animation always happen. Steps down at once, restores after 30 s. Default: off.", defaultValue: false)

    public static let threadQoS = NanogramDebugOption.toggle(id: "calls.threadQoS", section: CallVideoDebugOptions.section, title: "Thread priorities", detail: "Raises the call engine's media, worker and network threads to a higher system priority. Judge it by energy use, not by glitches. Default: off. Applies at once.", defaultValue: false)

    public static let all: [NanogramDebugOption] = [
        CallSystemDebugOptions.threadQoS,
        CallSystemDebugOptions.thermalVideoLadder
    ]

    public static func applyNativeOptions(from settings: NanogramDebugSettings) {
        TGCallsRuntimeOptionsBridge.setThreadQoSEnabled(settings.bool(CallSystemDebugOptions.threadQoS.id))
        let mode: CallThermalLadderMode = settings.bool(CallSystemDebugOptions.thermalVideoLadder.id) ? .uiAndVideo : .ui
        TGCallsRuntimeOptionsBridge.setThermalVideoLadderEnabled(mode == .uiAndVideo)
        CallPowerGovernor.shared.start(mode: mode)
    }
}

public enum LivestreamVideoVisibility {
    public static func update(isStream: Bool, isWindowVisible: Bool) {
        let suspend = LivestreamDecodePolicy.shouldSuspendVideo(enabled: true, isStream: isStream, isWindowVisible: isWindowVisible)
        TGCallsRuntimeOptionsBridge.setLivestreamVideoSuspended(suspend)
    }

    public static func clear() {
        TGCallsRuntimeOptionsBridge.setLivestreamVideoSuspended(false)
    }
}
