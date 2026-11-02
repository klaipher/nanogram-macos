import Foundation
import SwiftSignalKit

public final class DisplayLinkQueueClock {
    private let framesPerSecond: SharedDisplayLinkDriver.FramesPerSecond
    private let queue: Queue
    private let tick: () -> Void
    private let driver: () -> SharedDisplayLinkDriver
    private var lock = os_unfair_lock()
    private var wantsRunning = false
    private var isTickPending = false
    private var link: SharedDisplayLinkDriver.Link?

    public static func framesPerSecond(forFrameDuration duration: Double) -> SharedDisplayLinkDriver.FramesPerSecond {
        guard duration > 0 else {
            return .fps(60)
        }
        return .fps(max(1, Int((1.0 / duration).rounded())))
    }

    public convenience init(frameDuration: Double, queue: Queue, tick: @escaping () -> Void) {
        self.init(framesPerSecond: DisplayLinkQueueClock.framesPerSecond(forFrameDuration: frameDuration), queue: queue, driver: { SharedDisplayLinkDriver.shared }, tick: tick)
    }

    init(framesPerSecond: SharedDisplayLinkDriver.FramesPerSecond, queue: Queue, driver: @escaping () -> SharedDisplayLinkDriver, tick: @escaping () -> Void) {
        self.framesPerSecond = framesPerSecond
        self.queue = queue
        self.driver = driver
        self.tick = tick
    }

    deinit {
        os_unfair_lock_lock(&self.lock)
        let link = self.link
        self.link = nil
        os_unfair_lock_unlock(&self.lock)
        if let link = link {
            if Thread.isMainThread {
                link.invalidate()
            } else {
                DispatchQueue.main.async {
                    link.invalidate()
                }
            }
        }
    }

    public func start() {
        self.setRunning(true)
    }

    public func stop() {
        self.setRunning(false)
    }

    private var isRunning: Bool {
        os_unfair_lock_lock(&self.lock)
        defer {
            os_unfair_lock_unlock(&self.lock)
        }
        return self.wantsRunning
    }

    private func setRunning(_ value: Bool) {
        os_unfair_lock_lock(&self.lock)
        self.wantsRunning = value
        os_unfair_lock_unlock(&self.lock)
        if Thread.isMainThread {
            self.updateLink()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.updateLink()
            }
        }
    }

    private func updateLink() {
        os_unfair_lock_lock(&self.lock)
        let wantsRunning = self.wantsRunning
        let current = self.link
        if !wantsRunning {
            self.link = nil
        }
        os_unfair_lock_unlock(&self.lock)
        if wantsRunning {
            if current == nil {
                let link = self.driver().add(framesPerSecond: self.framesPerSecond, { [weak self] _ in
                    self?.fire()
                })
                os_unfair_lock_lock(&self.lock)
                self.link = link
                os_unfair_lock_unlock(&self.lock)
            }
        } else {
            current?.invalidate()
        }
    }

    private func fire() {
        if self.queue.isCurrent() {
            self.tick()
            return
        }
        os_unfair_lock_lock(&self.lock)
        if self.isTickPending {
            os_unfair_lock_unlock(&self.lock)
            return
        }
        self.isTickPending = true
        os_unfair_lock_unlock(&self.lock)
        self.queue.async { [weak self] in
            guard let self = self else {
                return
            }
            os_unfair_lock_lock(&self.lock)
            self.isTickPending = false
            let wantsRunning = self.wantsRunning
            os_unfair_lock_unlock(&self.lock)
            if wantsRunning {
                self.tick()
            }
        }
    }
}
