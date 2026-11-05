import Foundation

/// Decides whether a sticker keeps its VideoToolbox VP9 sessions. Hardware sessions are a capped,
/// shared resource (`VP9HardwareDecoding.maxConcurrentSessions`), so a sticker that can no longer use
/// one gives it back.
enum VP9SessionHoldPolicy {
    /// iOS AnimatedStickerNode keeps a hidden sticker's decoder for this long before releasing it.
    static let hiddenReleaseDelay: Double = 2.0

    static func shouldRelease(streamEnded: Bool, frameCacheComplete: Bool, hiddenFor: Double?) -> Bool {
        if streamEnded || frameCacheComplete {
            return true
        }
        if let hiddenFor {
            return hiddenFor >= VP9SessionHoldPolicy.hiddenReleaseDelay
        }
        return false
    }
}
