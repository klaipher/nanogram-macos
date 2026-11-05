import Foundation

enum StatusEmissionPolicy {
    static let playingHeartbeat: Double = 1.0 / 10.0

    static func shouldEmit(hasPreviousStatus: Bool, differsBeyondTiming: Bool, isPlayingLike: Bool, now: Double, lastEmitTimestamp: Double, timestampChanged: Bool) -> Bool {
        guard hasPreviousStatus else {
            return true
        }
        if differsBeyondTiming {
            return true
        }
        if isPlayingLike {
            return now - lastEmitTimestamp >= StatusEmissionPolicy.playingHeartbeat
        }
        return timestampChanged
    }
}
