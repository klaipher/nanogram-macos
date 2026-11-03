import Foundation

public final class PasslockMonitor {
    public typealias Schedule = (Double, @escaping () -> Void) -> () -> Void

    private let timeout: Int32
    private let wallClock: () -> Double
    private let idleTime: () -> Double
    private let resignedAt: () -> Int32?
    private let schedule: Schedule
    private let lock: () -> Void
    private var cancelTimer: (() -> Void)?
    private var isActive = false
    private var inactiveSinceAtSleep: Double?

    public init(timeout: Int32, wallClock: @escaping () -> Double, idleTime: @escaping () -> Double, resignedAt: @escaping () -> Int32?, schedule: @escaping Schedule, lock: @escaping () -> Void) {
        self.timeout = timeout
        self.wallClock = wallClock
        self.idleTime = idleTime
        self.resignedAt = resignedAt
        self.schedule = schedule
        self.lock = lock
    }

    public func start() {
        self.isActive = true
        self.check(idle: self.idleTime())
    }

    public func stop() {
        self.isActive = false
        self.inactiveSinceAtSleep = nil
        self.cancelTimer?()
        self.cancelTimer = nil
    }

    public func systemWillSleep() {
        guard self.isActive else {
            return
        }
        self.inactiveSinceAtSleep = self.wallClock() - self.idleTime()
    }

    public func systemDidWake() {
        guard self.isActive else {
            return
        }
        var idle = self.idleTime()
        if let inactiveSince = self.inactiveSinceAtSleep {
            idle = max(idle, self.wallClock() - inactiveSince)
        }
        self.inactiveSinceAtSleep = nil
        self.check(idle: idle)
    }

    private func check(idle: Double) {
        guard self.isActive else {
            return
        }
        self.cancelTimer?()
        self.cancelTimer = nil
        let now = Int32(self.wallClock())
        let resignedAt = self.resignedAt()
        if PasslockSchedule.shouldLock(timeout: self.timeout, idle: idle, resignedAt: resignedAt, now: now) {
            self.isActive = false
            self.lock()
            return
        }
        self.cancelTimer = self.schedule(PasslockSchedule.nextCheck(timeout: self.timeout, idle: idle, resignedAt: resignedAt, now: now), { [weak self] in
            guard let self else {
                return
            }
            self.cancelTimer = nil
            self.check(idle: self.idleTime())
        })
    }
}
