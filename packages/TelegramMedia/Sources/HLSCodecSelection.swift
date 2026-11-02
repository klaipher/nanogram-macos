import Foundation

public enum HLSCodecSelection {
    public static func isSupported(videoCodec: String, isHardwareAv1Supported: Bool) -> Bool {
        switch videoCodec {
        case "h264", "h265", "avc", "hevc":
            return true
        case "av1", "av01":
            return isHardwareAv1Supported
        default:
            return false
        }
    }

    public static func replaces(currentCodec: String?, with codec: String) -> Bool {
        if let currentCodec, isAv1(currentCodec) {
            return false
        }
        return true
    }

    private static func isAv1(_ codec: String) -> Bool {
        return codec == "av1" || codec == "av01"
    }
}
