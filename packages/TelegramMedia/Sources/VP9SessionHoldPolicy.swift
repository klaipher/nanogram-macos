import Foundation

enum VP9SessionHoldPolicy {
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
