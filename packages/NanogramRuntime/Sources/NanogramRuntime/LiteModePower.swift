import Foundation
import IOKit.ps

public struct PowerStateSnapshot: Equatable {
    public var batteryLevel: Double
    public var isLowPowerModeEnabled: Bool
    public var thermalState: ProcessInfo.ThermalState

    public init(batteryLevel: Double, isLowPowerModeEnabled: Bool, thermalState: ProcessInfo.ThermalState) {
        self.batteryLevel = batteryLevel
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
    }

    public static let unconstrained = PowerStateSnapshot(batteryLevel: 100, isLowPowerModeEnabled: false, thermalState: .nominal)
}

public enum LiteModePowerPolicy {
    public static let automaticPowerSavingOff: Int32 = 100

    public static func isLite(enabled: Bool, lowBatteryPercent: Int32, keyEnabled: Bool, power: PowerStateSnapshot) -> Bool {
        if enabled {
            return true
        }
        if lowBatteryPercent != automaticPowerSavingOff {
            if power.batteryLevel <= Double(lowBatteryPercent) {
                return true
            }
            if power.isLowPowerModeEnabled {
                return true
            }
            if power.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                return true
            }
        }
        return !keyEnabled
    }
}

public struct PowerStateReading {
    public let batteryLevel: () -> Double?
    public let isLowPowerModeEnabled: () -> Bool
    public let thermalState: () -> ProcessInfo.ThermalState

    public init(batteryLevel: @escaping () -> Double?, isLowPowerModeEnabled: @escaping () -> Bool, thermalState: @escaping () -> ProcessInfo.ThermalState) {
        self.batteryLevel = batteryLevel
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
    }

    public static let system = PowerStateReading(batteryLevel: {
        return internalBatteryLevel()
    }, isLowPowerModeEnabled: {
        if #available(macOS 12.0, *) {
            return ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        return false
    }, thermalState: {
        return ProcessInfo.processInfo.thermalState
    })
}

public func internalBatteryLevel() -> Double? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
        return nil
    }
    for source in sources {
        guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            continue
        }
        guard (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else {
            continue
        }
        guard let current = info[kIOPSCurrentCapacityKey] as? Int, let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 else {
            continue
        }
        return Double(current) / Double(maximum) * 100.0
    }
    return nil
}

public protocol PowerSourceObserving: AnyObject {
    func start(_ onChange: @escaping () -> Void)
    func stop()
}

public final class IOPowerSourceObserver: PowerSourceObserving {
    private final class Box {
        let onChange: () -> Void
        init(_ onChange: @escaping () -> Void) {
            self.onChange = onChange
        }
    }

    private var source: CFRunLoopSource?
    private var box: Unmanaged<Box>?

    public init() {
    }

    public func start(_ onChange: @escaping () -> Void) {
        self.stop()
        let box = Unmanaged.passRetained(Box(onChange))
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else {
                return
            }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().onChange()
        }, box.toOpaque())?.takeRetainedValue() else {
            box.release()
            return
        }
        self.box = box
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    public func stop() {
        if let source = self.source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            CFRunLoopSourceInvalidate(source)
            self.source = nil
        }
        self.box?.release()
        self.box = nil
    }

    deinit {
        self.stop()
    }
}

public final class PowerStateMonitor {
    public static let powerStateDidChangeNotification = Notification.Name.NSProcessInfoPowerStateDidChange

    private let reading: PowerStateReading
    private let batterySource: PowerSourceObserving
    private let notificationCenter: NotificationCenter
    private let onChange: (PowerStateSnapshot) -> Void
    private var observers: [NSObjectProtocol] = []
    private var observesBattery = false

    public private(set) var state: PowerStateSnapshot

    public init(reading: PowerStateReading = .system, batterySource: PowerSourceObserving = IOPowerSourceObserver(), notificationCenter: NotificationCenter = .default, onChange: @escaping (PowerStateSnapshot) -> Void) {
        self.reading = reading
        self.batterySource = batterySource
        self.notificationCenter = notificationCenter
        self.onChange = onChange
        self.state = PowerStateSnapshot(batteryLevel: 100, isLowPowerModeEnabled: reading.isLowPowerModeEnabled(), thermalState: reading.thermalState())
        for name in [PowerStateMonitor.powerStateDidChangeNotification, ProcessInfo.thermalStateDidChangeNotification] {
            self.observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: nil, using: { [weak self] _ in
                if Thread.isMainThread {
                    self?.refresh()
                } else {
                    DispatchQueue.main.async {
                        self?.refresh()
                    }
                }
            }))
        }
    }

    deinit {
        for observer in self.observers {
            self.notificationCenter.removeObserver(observer)
        }
        if self.observesBattery {
            self.batterySource.stop()
        }
    }

    public func setObservesBattery(_ value: Bool) {
        if value {
            guard !self.observesBattery, self.reading.batteryLevel() != nil else {
                return
            }
            self.observesBattery = true
            self.batterySource.start({ [weak self] in
                self?.refresh()
            })
        } else {
            guard self.observesBattery else {
                return
            }
            self.observesBattery = false
            self.batterySource.stop()
        }
        self.refresh()
    }

    public func refresh() {
        let battery = self.observesBattery ? (self.reading.batteryLevel() ?? 100) : 100
        let updated = PowerStateSnapshot(batteryLevel: battery, isLowPowerModeEnabled: self.reading.isLowPowerModeEnabled(), thermalState: self.reading.thermalState())
        if updated != self.state {
            self.state = updated
            self.onChange(updated)
        }
    }
}
