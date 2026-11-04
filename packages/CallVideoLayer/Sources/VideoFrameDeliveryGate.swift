import Foundation

public final class VideoFrameDeliveryGate {
    private let lock = NSLock()
    private var isSuspendedValue = false
    private var hasDeliveredFrame = false

    public init() {
    }

    public var isSuspended: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.isSuspendedValue
    }

    public func setSuspended(_ suspended: Bool) {
        self.lock.lock()
        self.isSuspendedValue = suspended
        self.lock.unlock()
    }

    public func admit() -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.isSuspendedValue && self.hasDeliveredFrame {
            return false
        }
        self.hasDeliveredFrame = true
        return true
    }
}

public enum CallAnimationFrameRate {
    public static func blobFramesPerSecond(reducedEffects: Bool) -> Int {
        return reducedEffects ? 30 : 60
    }
}

public enum LivestreamDecodePolicy {
    public static func shouldSuspendVideo(enabled: Bool, isStream: Bool, isWindowVisible: Bool) -> Bool {
        return enabled && isStream && !isWindowVisible
    }
}

public enum StatusBarPulsePolicy {
    public static let animatedInterval: TimeInterval = 0.25

    public static func interval(power: CallPowerStep) -> TimeInterval? {
        return power >= .serious ? nil : StatusBarPulsePolicy.animatedInterval
    }
}
