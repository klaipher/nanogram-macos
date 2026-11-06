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

struct VP9HiddenReleaseGate {
    private(set) var generation: Int = 0
    private(set) var isHidden = false

    mutating func hide() -> Int {
        self.generation += 1
        self.isHidden = true
        return self.generation
    }

    mutating func show() {
        self.generation += 1
        self.isHidden = false
    }

    func shouldRelease(scheduledGeneration: Int) -> Bool {
        return self.isHidden && self.generation == scheduledGeneration
    }
}
