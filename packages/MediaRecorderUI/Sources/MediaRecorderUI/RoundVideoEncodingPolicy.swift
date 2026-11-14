import Foundation

public enum RoundVideoEncodingPolicy {
    public static let minimumSide = 480
    public static let maximumSide = 640
    public static let minimumVideoBitrateKbps = 1200
    public static let minimumAudioBitrateKbps = 64
    public static let frameRate = 30

    public static func side(serverDiameter: Int) -> Int {
        let side = min(maximumSide, max(minimumSide, serverDiameter))
        return side & ~1
    }

    public static func videoBitrateKbps(server: Int) -> Int {
        return max(minimumVideoBitrateKbps, server)
    }

    public static func audioBitrateKbps(server: Int) -> Int {
        return max(minimumAudioBitrateKbps, server)
    }

    public static func effectiveSide(side: Int, sourceShortSide: Int) -> Int {
        guard sourceShortSide > 0 else {
            return side
        }
        return min(side, sourceShortSide) & ~1
    }
}
