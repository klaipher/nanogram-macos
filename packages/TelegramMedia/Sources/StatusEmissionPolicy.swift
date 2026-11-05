import Foundation

/// Decides whether a recomputed player status goes out to observers.
/// Pure so it can be tested without a player.
enum StatusEmissionPolicy {
    /// Observers extrapolate a playing clock from the status, so a playing player only needs a heartbeat.
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
