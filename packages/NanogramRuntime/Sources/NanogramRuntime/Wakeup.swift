import Foundation

public struct AccountWakeupFlags: Equatable {
    public var serviceTaskMaster: Bool
    public var keepWorkerConnections: Bool
    public var keepOnlinePresence: Bool
    public var keepBackgroundDownloads: Bool

    public init(serviceTaskMaster: Bool, keepWorkerConnections: Bool, keepOnlinePresence: Bool, keepBackgroundDownloads: Bool) {
        self.serviceTaskMaster = serviceTaskMaster
        self.keepWorkerConnections = keepWorkerConnections
        self.keepOnlinePresence = keepOnlinePresence
        self.keepBackgroundDownloads = keepBackgroundDownloads
    }
}

public enum AccountWakeupFlag: CaseIterable, Hashable {
    case serviceTaskMaster
    case keepWorkerConnections
    case keepOnlinePresence
    case keepBackgroundDownloads

    func value(in flags: AccountWakeupFlags) -> Bool {
        switch self {
        case .serviceTaskMaster:
            return flags.serviceTaskMaster
        case .keepWorkerConnections:
            return flags.keepWorkerConnections
        case .keepOnlinePresence:
            return flags.keepOnlinePresence
        case .keepBackgroundDownloads:
            return flags.keepBackgroundDownloads
        }
    }
}

public final class AccountWakeupFlagsCache<Key: Hashable> {
    private var applied: [Key: [AccountWakeupFlag: Bool]] = [:]

    public init() {
    }

    public func changes(for key: Key, _ flags: AccountWakeupFlags) -> [AccountWakeupFlag] {
        var current = self.applied[key] ?? [:]
        var result: [AccountWakeupFlag] = []
        for flag in AccountWakeupFlag.allCases {
            let value = flag.value(in: flags)
            if current[flag] != value {
                current[flag] = value
                result.append(flag)
            }
        }
        self.applied[key] = current
        return result
    }

    public func invalidate(_ flag: AccountWakeupFlag) {
        for key in Array(self.applied.keys) {
            self.applied[key]?.removeValue(forKey: flag)
        }
    }

    public func keep(only keys: Set<Key>) {
        for key in Array(self.applied.keys) where !keys.contains(key) {
            self.applied.removeValue(forKey: key)
        }
    }
}

public struct SleepState: Equatable {
    public private(set) var isSystemSleeping = false
    public private(set) var isScreenSleeping = false

    public init() {
    }

    public var isSleeping: Bool {
        return self.isSystemSleeping || self.isScreenSleeping
    }

    public var keepsNetwork: Bool {
        return !self.isSystemSleeping
    }

    public mutating func systemWillSleep() {
        self.isSystemSleeping = true
    }

    public mutating func systemDidWake() {
        self.isSystemSleeping = false
    }

    public mutating func screensDidSleep() {
        self.isScreenSleeping = true
    }

    public mutating func screensDidWake() {
        self.isScreenSleeping = false
    }
}

public enum PresenceIdleSchedule {
    public static let idleThreshold: Double = 30
    public static let returnPollInterval: Double = 5

    public static func nextCheck(isActive: Bool, isSleeping: Bool = false, isScreenLocked: Bool = false, idleTime: Double) -> Double? {
        guard isActive, !isSleeping, !isScreenLocked else {
            return nil
        }
        if idleTime >= idleThreshold {
            return returnPollInterval
        }
        return max(1, (idleThreshold - idleTime).rounded(.up))
    }
}

public enum PasslockSchedule {
    public static func shouldLock(timeout: Int32, idle: Double, resignedAt: Int32?, now: Int32) -> Bool {
        if let resignedAt = resignedAt, Int64(now) - Int64(resignedAt) > Int64(timeout) {
            return true
        }
        return idle > Double(timeout)
    }

    public static func nextCheck(timeout: Int32, idle: Double, resignedAt: Int32?, now: Int32) -> Double {
        var result = Double(timeout) - idle + 1
        if let resignedAt = resignedAt {
            result = min(result, Double(Int64(resignedAt) + Int64(timeout) - Int64(now) + 1))
        }
        return max(1, result)
    }
}
