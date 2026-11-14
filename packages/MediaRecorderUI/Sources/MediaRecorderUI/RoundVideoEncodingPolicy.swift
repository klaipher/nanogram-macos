import Foundation

public enum RoundVideoEncodingPolicy {
    public static let minimumSide = 480
    public static let maximumSide = 640
    public static let minimumVideoBitrateKbps = 1200
    public static let minimumAudioBitrateKbps = 64
    public static let frameRate = 30
    public static let captureHeadroom = 1.25

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

    public static func targetCaptureShortSide(side: Int) -> Int {
        return Int((Double(side) * captureHeadroom).rounded(.up))
    }

    public static func effectiveSide(side: Int, sourceShortSide: Int) -> Int {
        guard sourceShortSide > 0 else {
            return side
        }
        return min(side, sourceShortSide) & ~1
    }

    public struct CaptureFormatCandidate: Equatable {
        public let shortSide: Int
        public let supportsFrameRate: Bool

        public init(shortSide: Int, supportsFrameRate: Bool) {
            self.shortSide = shortSide
            self.supportsFrameRate = supportsFrameRate
        }
    }

    public static func bestCaptureFormat(_ candidates: [CaptureFormatCandidate], side: Int) -> Int? {
        let usable = candidates.enumerated().filter { $0.element.supportsFrameRate && $0.element.shortSide > 0 }
        guard !usable.isEmpty else {
            return nil
        }
        let target = targetCaptureShortSide(side: side)
        let large = usable.filter { $0.element.shortSide >= target }
        if let best = large.min(by: { $0.element.shortSide < $1.element.shortSide }) {
            return best.offset
        }
        return usable.max(by: { $0.element.shortSide < $1.element.shortSide })?.offset
    }
}
