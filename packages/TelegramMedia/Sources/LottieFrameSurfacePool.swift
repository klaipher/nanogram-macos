import Foundation
import QuartzCore
import IOSurface
import TGUIKit

public final class LottieFrameSurface {
    public let surface: IOSurface
    fileprivate let slot: LottieFrameSurfacePool.Slot
    private weak var pool: LottieFrameSurfacePool?

    fileprivate init(slot: LottieFrameSurfacePool.Slot, pool: LottieFrameSurfacePool) {
        self.surface = slot.surface
        self.slot = slot
        self.pool = pool
    }

    deinit {
        self.pool?.release(self.slot)
    }
}

public final class LottieFrameSurfacePool {
    public static let shared = LottieFrameSurfacePool()

    fileprivate final class Slot {
        let surface: IOSurface
        var leases: Int = 0
        var releasedAt: Double

        init(surface: IOSurface, now: Double) {
            self.surface = surface
            self.releasedAt = now
        }
    }

    private struct Size: Hashable {
        let width: Int
        let height: Int
    }

    static let reuseDelay: Double = 0.05
    static let idleLifetime: Double = 5.0

    var now: () -> Double = {
        return CFAbsoluteTimeGetCurrent()
    }

    static let defaultScheduleTrim: (Double, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    var scheduleTrim: (Double, @escaping () -> Void) -> Void = LottieFrameSurfacePool.defaultScheduleTrim {
        didSet {
            self.lock.lock()
            self.trimPending = false
            self.lock.unlock()
        }
    }

    private let lock = NSLock()
    private var slots: [Size: [Slot]] = [:]
    private var _createdCount: Int = 0
    private var lastTrim: Double = 0
    private var trimPending = false

    var retainedCount: Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.slots.values.reduce(0) { $0 + $1.count }
    }

    var createdCount: Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self._createdCount
    }

    func surface(copying source: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, colorSpace: CGColorSpace) -> LottieFrameSurface? {
        guard let lease = self.take(width: width, height: height, colorSpace: colorSpace) else {
            return nil
        }
        let surface = lease.surface
        surface.lock(options: [], seed: nil)
        let destination = surface.baseAddress
        let destinationBytesPerRow = surface.bytesPerRow
        if destinationBytesPerRow == bytesPerRow {
            memcpy(destination, source, bytesPerRow * height)
        } else {
            let rowLength = min(bytesPerRow, destinationBytesPerRow)
            for y in 0 ..< height {
                memcpy(destination + y * destinationBytesPerRow, source + y * bytesPerRow, rowLength)
            }
        }
        surface.unlock(options: [], seed: nil)
        return lease
    }

    private func take(width: Int, height: Int, colorSpace: CGColorSpace) -> LottieFrameSurface? {
        let now = self.now()
        let size = Size(width: width, height: height)
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if now - self.lastTrim > 1.0 {
            self.trimIdleLocked(now: now)
        }
        var list = self.slots[size] ?? []
        var candidate: Slot?
        for slot in list where slot.leases == 0 && now - slot.releasedAt >= LottieFrameSurfacePool.reuseDelay && !slot.surface.isInUse {
            if candidate == nil || slot.releasedAt < candidate!.releasedAt {
                candidate = slot
            }
        }
        if candidate == nil {
            let properties: [IOSurfacePropertyKey: Any] = [
                .width: width,
                .height: height,
                .bytesPerElement: 4,
                .pixelFormat: kCVPixelFormatType_32BGRA
            ]
            guard let surface = IOSurface(properties: properties) else {
                self.slots[size] = list
                return nil
            }
            if let colorSpaceProperties = colorSpace.copyPropertyList() {
                IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colorSpaceProperties)
            }
            let slot = Slot(surface: surface, now: now)
            list.append(slot)
            self._createdCount += 1
            candidate = slot
        }
        self.slots[size] = list
        let slot = candidate!
        slot.leases += 1
        return LottieFrameSurface(slot: slot, pool: self)
    }

    private func trimIdleLocked(now: Double) {
        self.lastTrim = now
        for (key, value) in self.slots {
            let kept = value.filter { slot in
                return !(slot.leases == 0 && now - slot.releasedAt > LottieFrameSurfacePool.idleLifetime && !slot.surface.isInUse)
            }
            self.slots[key] = kept.isEmpty ? nil : kept
        }
    }

    private func scheduleIdleTrimLocked() -> Bool {
        if self.trimPending {
            return false
        }
        self.trimPending = true
        return true
    }

    private func runScheduledTrim() {
        let now = self.now()
        self.lock.lock()
        self.trimPending = false
        self.trimIdleLocked(now: now)
        let hasIdle = self.slots.values.contains(where: { $0.contains(where: { $0.leases == 0 }) })
        let schedule = hasIdle && self.scheduleIdleTrimLocked()
        self.lock.unlock()
        if schedule {
            self.armTrim()
        }
    }

    private func armTrim() {
        self.scheduleTrim(LottieFrameSurfacePool.idleLifetime + 1.0, { [weak self] in
            self?.runScheduledTrim()
        })
    }

    fileprivate func release(_ slot: Slot) {
        let now = self.now()
        self.lock.lock()
        slot.leases -= 1
        var schedule = false
        if slot.leases == 0 {
            slot.releasedAt = now
            schedule = self.scheduleIdleTrimLocked()
        }
        self.lock.unlock()
        if schedule {
            self.armTrim()
        }
    }
}

private let lottieFrameSurfaceLeaseKey = "nanogramLottieFrameSurface"

public extension CALayer {
    func setLottieFrame(_ frame: RenderedFrame?) {
        if let lease = frame?.surface {
            self.contents = lease.surface
            self.setValue(lease, forKey: lottieFrameSurfaceLeaseKey)
        } else {
            self.contents = frame?.image
            self.setValue(nil, forKey: lottieFrameSurfaceLeaseKey)
        }
    }
}
