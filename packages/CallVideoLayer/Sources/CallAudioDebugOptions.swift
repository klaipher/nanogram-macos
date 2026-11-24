import Foundation
import NanogramDebug
import TgVoipWebrtc

public enum CallAudioDebugOptions {
    public static let groupNoiseMode = NanogramDebugOption.choice(id: "calls.groupNoiseMode", section: CallVideoDebugOptions.section, title: "Group noise suppression", detail: "Which noise suppressors run in group calls. Both: WebRTC's suppressor and RNNoise. One: only the chosen one, which saves CPU. Default: RNNoise only. Applies to the next group call.", options: [
        NanogramDebugChoice(id: "both", title: "Both"),
        NanogramDebugChoice(id: "apm", title: "WebRTC suppressor only"),
        NanogramDebugChoice(id: "rnnoise", title: "RNNoise only (default)")
    ], defaultValue: "rnnoise").userFacing("Which noise suppressors run in group calls. RNNoise only is the default and uses the least CPU. Applies to the next group call.")

    public static let all: [NanogramDebugOption] = [
        CallAudioDebugOptions.groupNoiseMode
    ]

    public static func groupNoiseModeValue(_ choice: String?) -> Int {
        switch choice {
        case "apm": return 1
        case "rnnoise": return 2
        default: return 0
        }
    }

    public static func applyNativeOptions(from settings: NanogramDebugSettings) {
        TGCallsRuntimeOptionsBridge.setGroupNoiseMode(CallAudioDebugOptions.groupNoiseModeValue(settings.choice(CallAudioDebugOptions.groupNoiseMode.id)))
    }
}
