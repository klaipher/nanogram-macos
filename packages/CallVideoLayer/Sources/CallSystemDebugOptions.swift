import Foundation
import NanogramDebug
import TgVoipWebrtc

public enum CallSystemDebugOptions {
    public static let thermalLadder = NanogramDebugOption.choice(id: "calls.thermalLadder", section: CallVideoDebugOptions.section, title: "Thermal and Low Power steps", detail: "When the Mac runs warm or in Low Power Mode: UI only drops blur backdrops and slows decorative animation; UI and video also lowers the resolution and frame rate of your outgoing camera video (540p/20 fps serious, 480p/15 fps critical or Low Power Mode). Steps down at once, restores after 30 s.", options: [
        NanogramDebugChoice(id: "off", title: "Off"),
        NanogramDebugChoice(id: "ui", title: "UI only (default)"),
        NanogramDebugChoice(id: "uiAndVideo", title: "UI and outgoing video")
    ], defaultValue: "ui")

    public static let suspendHiddenLivestream = NanogramDebugOption.toggle(id: "calls.suspendHiddenLivestream", section: CallVideoDebugOptions.section, title: "Livestream: stop video decode while the window is hidden", detail: "Audio keeps playing; video decoding stops while the stream window is minimised or fully covered and resumes when it is shown. Off: video always decodes.", defaultValue: true)

    public static let threadQoS = NanogramDebugOption.toggle(id: "calls.threadQoS", section: CallVideoDebugOptions.section, title: "Call engine threads: user-initiated QoS", detail: "Raises the call engine's media, worker and network threads from default to user-initiated priority. Off: system default.", defaultValue: false)

    public static let all: [NanogramDebugOption] = [
        CallSystemDebugOptions.thermalLadder,
        CallSystemDebugOptions.suspendHiddenLivestream,
        CallSystemDebugOptions.threadQoS
    ]

    public static func isSuspendHiddenLivestreamEnabled(in settings: NanogramDebugSettings = NanogramDebugSettings.shared) -> Bool {
        return settings.bool(CallSystemDebugOptions.suspendHiddenLivestream.id)
    }

    public static func applyNativeOptions(from settings: NanogramDebugSettings) {
        TGCallsRuntimeOptionsBridge.setThreadQoSEnabled(settings.bool(CallSystemDebugOptions.threadQoS.id))
        let mode = CallThermalLadderMode(choice: settings.choice(CallSystemDebugOptions.thermalLadder.id))
        CallPowerGovernor.shared.start(mode: mode)
    }
}

public enum LivestreamVideoVisibility {
    public static func update(isStream: Bool, isWindowVisible: Bool, in settings: NanogramDebugSettings = NanogramDebugSettings.shared) {
        let suspend = LivestreamDecodePolicy.shouldSuspendVideo(enabled: CallSystemDebugOptions.isSuspendHiddenLivestreamEnabled(in: settings), isStream: isStream, isWindowVisible: isWindowVisible)
        TGCallsRuntimeOptionsBridge.setLivestreamVideoSuspended(suspend)
    }

    public static func clear() {
        TGCallsRuntimeOptionsBridge.setLivestreamVideoSuspended(false)
    }
}
