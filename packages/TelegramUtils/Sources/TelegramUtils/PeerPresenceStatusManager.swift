import Cocoa

import SwiftSignalKit
import TelegramCore
#if SHARE
import TelegramThemeShare
import TelegramContextShare
#else
import TelegramTheme
import TelegramContext
#endif

public protocol PeerPresenceStatusManagerEnvironment: AnyObject {
    var currentTimestamp: Double { get }
    var isApplicationInBackground: Bool { get }
    func scheduleTimer(timeout: Double, _ f: @escaping () -> Void) -> Disposable
    func addApplicationStateListener(_ f: @escaping () -> Void) -> Disposable
}

private final class DefaultPeerPresenceStatusManagerEnvironment: PeerPresenceStatusManagerEnvironment, @unchecked Sendable {
    static let shared = DefaultPeerPresenceStatusManagerEnvironment()

    private let lock = NSLock()
    private var listeners = Bag<() -> Void>()
    private var isInBackground = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: OperationQueue.main, using: { [weak self] _ in
            self?.setInBackground(!DefaultPeerPresenceStatusManagerEnvironment.isApplicationVisible())
        }))
        self.observers.append(center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: OperationQueue.main, using: { [weak self] _ in
            self?.setInBackground(true)
        }))
        self.observers.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: OperationQueue.main, using: { [weak self] _ in
            self?.setInBackground(!DefaultPeerPresenceStatusManagerEnvironment.isApplicationVisible())
        }))
    }

    private static func isApplicationVisible() -> Bool {
        return MainActor.assumeIsolated {
            NSApplication.shared.occlusionState.contains(.visible)
        }
    }

    private func setInBackground(_ value: Bool) {
        self.lock.lock()
        let changed = self.isInBackground != value
        self.isInBackground = value
        let listeners = changed ? self.listeners.copyItems() : []
        self.lock.unlock()
        for f in listeners {
            f()
        }
    }

    var currentTimestamp: Double {
        return CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970
    }

    var isApplicationInBackground: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.isInBackground
    }

    func scheduleTimer(timeout: Double, _ f: @escaping () -> Void) -> Disposable {
        let timer = SwiftSignalKit.Timer(timeout: timeout, repeat: false, completion: f, queue: Queue.mainQueue())
        timer.start()
        return ActionDisposable {
            timer.invalidate()
        }
    }

    func addApplicationStateListener(_ f: @escaping () -> Void) -> Disposable {
        self.lock.lock()
        let index = self.listeners.add(f)
        self.lock.unlock()
        return ActionDisposable { [weak self] in
            guard let self else {
                return
            }
            self.lock.lock()
            self.listeners.remove(index)
            self.lock.unlock()
        }
    }
}

public final class PeerPresenceStatusManager {
    private let update: () -> Void
    private let mode: PeerPresenceStatusRefreshMode
    private let environment: PeerPresenceStatusManagerEnvironment

    private var deadline: Double?
    private var isSuspended = false
    private var timer: Disposable?
    private var applicationStateDisposable: Disposable?

    public convenience init(update: @escaping () -> Void) {
        self.init(mode: .statusText, update: update)
    }

    public convenience init(mode: PeerPresenceStatusRefreshMode, update: @escaping () -> Void) {
        self.init(mode: mode, environment: DefaultPeerPresenceStatusManagerEnvironment.shared, update: update)
    }

    public init(mode: PeerPresenceStatusRefreshMode, environment: PeerPresenceStatusManagerEnvironment, update: @escaping () -> Void) {
        self.mode = mode
        self.environment = environment
        self.update = update

        self.applicationStateDisposable = environment.addApplicationStateListener({ [weak self] in
            self?.applicationStateUpdated()
        })
    }

    deinit {
        self.timer?.dispose()
        self.applicationStateDisposable?.dispose()
    }

    public func reset(presence: TelegramUserPresence, timeDifference: Int32) {
        self.timer?.dispose()
        self.timer = nil
        self.deadline = nil

        let timestamp = self.environment.currentTimestamp
        let timeout = peerPresenceStatusRefreshTimeout(presence, timeDifference: timeDifference, relativeTo: timestamp, mode: self.mode)
        if timeout.isFinite {
            self.deadline = timestamp + timeout
            self.scheduleTimerIfNeeded()
        }
    }

    public func suspend() {
        self.isSuspended = true
        self.timer?.dispose()
        self.timer = nil
    }

    public func resume() {
        guard self.isSuspended else {
            return
        }
        self.isSuspended = false
        self.applicationStateUpdated()
    }

    private func scheduleTimerIfNeeded() {
        guard self.timer == nil, !self.isSuspended, let deadline = self.deadline, !self.environment.isApplicationInBackground else {
            return
        }
        let timeout = max(0.0, deadline - self.environment.currentTimestamp)
        self.timer = self.environment.scheduleTimer(timeout: timeout, { [weak self] in
            self?.timerFired()
        })
    }

    private func timerFired() {
        self.timer?.dispose()
        self.timer = nil
        if self.environment.isApplicationInBackground {
            return
        }
        self.deadline = nil
        self.update()
    }

    private func applicationStateUpdated() {
        if self.isSuspended {
            return
        }
        if self.environment.isApplicationInBackground {
            self.timer?.dispose()
            self.timer = nil
        } else if let deadline = self.deadline, self.timer == nil {
            if self.environment.currentTimestamp >= deadline {
                self.deadline = nil
                self.update()
            } else {
                self.scheduleTimerIfNeeded()
            }
        }
    }
}
