import Foundation
import NanogramDebug
import TgVoipWebrtc

public enum CallPowerStep: Int, Comparable, CustomStringConvertible {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: CallPowerStep, rhs: CallPowerStep) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }
}

public struct CallPowerInputs: Equatable {
    public var thermalState: ProcessInfo.ThermalState
    public var isLowPowerModeEnabled: Bool

    public init(thermalState: ProcessInfo.ThermalState, isLowPowerModeEnabled: Bool) {
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    public static func current() -> CallPowerInputs {
        return CallPowerInputs(thermalState: ProcessInfo.processInfo.thermalState, isLowPowerModeEnabled: CallPowerInputs.systemLowPowerMode())
    }

    private static func systemLowPowerMode() -> Bool {
        if #available(macOS 12.0, *) {
            return ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        return false
    }
}

public enum CallThermalLadderMode: String, Equatable {
    case off
    case ui
    case uiAndVideo

    public init(choice: String?) {
        self = CallThermalLadderMode(rawValue: choice ?? "") ?? .ui
    }
}

public struct CallPowerProfile: Equatable, Sendable {
    public var reducedEffects: Bool
    public var maxShortSide: Int
    public var maxFps: Int

    public init(reducedEffects: Bool, maxShortSide: Int, maxFps: Int) {
        self.reducedEffects = reducedEffects
        self.maxShortSide = maxShortSide
        self.maxFps = maxFps
    }

    public static let full = CallPowerProfile(reducedEffects: false, maxShortSide: 0, maxFps: 0)
}

public enum CallPowerPolicy {
    public static func step(for inputs: CallPowerInputs) -> CallPowerStep {
        var step: CallPowerStep
        switch inputs.thermalState {
        case .nominal: step = .nominal
        case .fair: step = .fair
        case .serious: step = .serious
        case .critical: step = .critical
        @unknown default: step = .critical
        }
        if inputs.isLowPowerModeEnabled {
            step = max(step, .fair)
        }
        return step
    }

    public static func profile(step: CallPowerStep, mode: CallThermalLadderMode) -> CallPowerProfile {
        guard mode != .off, step > .nominal else {
            return .full
        }
        var profile = CallPowerProfile(reducedEffects: true, maxShortSide: 0, maxFps: 0)
        if mode == .uiAndVideo {
            switch step {
            case .nominal, .fair:
                break
            case .serious:
                profile.maxShortSide = 540
                profile.maxFps = 20
            case .critical:
                profile.maxShortSide = 360
                profile.maxFps = 15
            }
        }
        return profile
    }
}

public struct CallPowerHysteresis {
    public static let restoreDelay: TimeInterval = 30.0

    public private(set) var step: CallPowerStep
    private var restoreWindowStart: TimeInterval?
    private var restoreCeiling: CallPowerStep = .nominal

    public init(step: CallPowerStep = .nominal) {
        self.step = step
    }

    public var isRestorePending: Bool {
        return self.restoreWindowStart != nil
    }

    public mutating func update(target: CallPowerStep, now: TimeInterval) -> CallPowerStep? {
        if target >= self.step {
            self.restoreWindowStart = nil
            if target > self.step {
                self.step = target
                return target
            }
            return nil
        }
        if let start = self.restoreWindowStart {
            self.restoreCeiling = max(self.restoreCeiling, target)
            if now - start >= CallPowerHysteresis.restoreDelay {
                let restored = self.restoreCeiling
                var changed: CallPowerStep?
                if restored < self.step {
                    self.step = restored
                    changed = restored
                }
                if target < self.step {
                    // The real state is still lower than the restored step: open the next window so the
                    // step keeps coming down without waiting for another system notification.
                    self.restoreWindowStart = now
                    self.restoreCeiling = target
                } else {
                    self.restoreWindowStart = nil
                }
                return changed
            }
        } else {
            self.restoreWindowStart = now
            self.restoreCeiling = target
        }
        return nil
    }
}

public final class CallPowerGovernor: @unchecked Sendable {
    public static let shared = CallPowerGovernor()

    public final class Token {
        fileprivate var cancel: (() -> Void)?

        fileprivate init(cancel: @escaping () -> Void) {
            self.cancel = cancel
        }

        public func invalidate() {
            self.cancel?()
            self.cancel = nil
        }

        deinit {
            self.invalidate()
        }
    }

    public typealias Scheduled = () -> Void

    private let readInputs: () -> CallPowerInputs
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Scheduled
    private let applyThermalLevel: (Int) -> Void
    private let log: (String) -> Void
    private let notificationCenter: NotificationCenter

    private var observers: [NSObjectProtocol] = []
    private var hysteresis = CallPowerHysteresis()
    private var cancelRestore: Scheduled?
    private var listeners: [Int: (CallPowerProfile) -> Void] = [:]
    private var nextListenerId = 0
    private var mode: CallThermalLadderMode = .ui
    private var started = false

    public private(set) var profile: CallPowerProfile = .full
    public var step: CallPowerStep {
        return self.hysteresis.step
    }

    public init(
        readInputs: @escaping () -> CallPowerInputs = { CallPowerInputs.current() },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Scheduled = { delay, work in
            let item = DispatchWorkItem(block: work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        },
        applyThermalLevel: @escaping (Int) -> Void = { level in
            TGCallsRuntimeOptionsBridge.setThermalLevel(level)
        },
        log: @escaping (String) -> Void = { NSLog("%@", $0) },
        notificationCenter: NotificationCenter = .default
    ) {
        self.readInputs = readInputs
        self.now = now
        self.schedule = schedule
        self.applyThermalLevel = applyThermalLevel
        self.log = log
        self.notificationCenter = notificationCenter
    }

    deinit {
        self.stop()
    }

    public func start(mode: CallThermalLadderMode) {
        self.setMode(mode)
        if !self.started {
            self.started = true
            let names: [Notification.Name] = [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
            for name in names {
                self.observers.append(self.notificationCenter.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] _ in
                    self?.refresh()
                }))
            }
        }
        self.refresh()
    }

    public func setMode(_ mode: CallThermalLadderMode) {
        guard self.mode != mode else {
            return
        }
        self.mode = mode
        self.publishProfile(reason: "mode \(mode.rawValue)")
    }

    public func stop() {
        for observer in self.observers {
            self.notificationCenter.removeObserver(observer)
        }
        self.observers.removeAll()
        self.cancelRestore?()
        self.cancelRestore = nil
        self.started = false
    }

    public func observe(_ listener: @escaping (CallPowerProfile) -> Void) -> Token {
        let id = self.nextListenerId
        self.nextListenerId += 1
        self.listeners[id] = listener
        listener(self.profile)
        return Token(cancel: { [weak self] in
            self?.listeners[id] = nil
        })
    }

    public var listenerCount: Int {
        return self.listeners.count
    }

    public func refresh() {
        let inputs = self.readInputs()
        let target = CallPowerPolicy.step(for: inputs)
        let changed = self.hysteresis.update(target: target, now: self.now())
        self.cancelRestore?()
        self.cancelRestore = nil
        if self.hysteresis.isRestorePending {
            self.cancelRestore = self.schedule(CallPowerHysteresis.restoreDelay, { [weak self] in
                self?.cancelRestore = nil
                self?.refresh()
            })
        }
        if let changed = changed {
            self.log("Call power step -> \(changed) (thermal \(inputs.thermalState.rawValue), low power \(inputs.isLowPowerModeEnabled))")
            self.publishProfile(reason: "step \(changed)")
        }
    }

    private func publishProfile(reason: String) {
        let updated = CallPowerPolicy.profile(step: self.hysteresis.step, mode: self.mode)
        guard updated != self.profile else {
            return
        }
        let previous = self.profile
        self.profile = updated
        if previous.maxShortSide != updated.maxShortSide || previous.maxFps != updated.maxFps {
            self.log("Call outgoing video cap \(updated.maxShortSide)p at \(updated.maxFps) fps (\(reason))")
        }
        self.applyThermalLevel(updated.maxShortSide == 0 ? 0 : self.hysteresis.step.rawValue)
        for listener in Array(self.listeners.values) {
            listener(updated)
        }
    }
}
