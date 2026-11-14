import Darwin
import Foundation
import IOKit.ps

// Kept next to, not on, iOS's shared EnergyNumbers module: the Mac's core pin predates that module, and moving needs a pin bump.

/// Cumulative kernel counters of this process; two samples give the cost of the time between them.
public struct NanogramEnergySample: Equatable, Sendable {
    public var date: Date
    public var cpuUserSeconds: Double
    public var cpuSystemSeconds: Double
    public var billedEnergyNanojoules: UInt64
    public var taskEnergyNanojoules: UInt64
    public var instructions: UInt64
    public var cycles: UInt64
    public var interruptWakeups: UInt64
    public var idleWakeups: UInt64

    public init(date: Date, cpuUserSeconds: Double = 0, cpuSystemSeconds: Double = 0, billedEnergyNanojoules: UInt64 = 0, taskEnergyNanojoules: UInt64 = 0, instructions: UInt64 = 0, cycles: UInt64 = 0, interruptWakeups: UInt64 = 0, idleWakeups: UInt64 = 0) {
        self.date = date
        self.cpuUserSeconds = cpuUserSeconds
        self.cpuSystemSeconds = cpuSystemSeconds
        self.billedEnergyNanojoules = billedEnergyNanojoules
        self.taskEnergyNanojoules = taskEnergyNanojoules
        self.instructions = instructions
        self.cycles = cycles
        self.interruptWakeups = interruptWakeups
        self.idleWakeups = idleWakeups
    }

    public func since(_ base: NanogramEnergySample) -> NanogramEnergyDelta {
        func diff(_ a: UInt64, _ b: UInt64) -> UInt64 {
            return a >= b ? a - b : 0
        }
        return NanogramEnergyDelta(
            wallSeconds: max(0, self.date.timeIntervalSince(base.date)),
            cpuSeconds: max(0, (self.cpuUserSeconds + self.cpuSystemSeconds) - (base.cpuUserSeconds + base.cpuSystemSeconds)),
            billedEnergyNanojoules: diff(self.billedEnergyNanojoules, base.billedEnergyNanojoules),
            taskEnergyNanojoules: diff(self.taskEnergyNanojoules, base.taskEnergyNanojoules),
            instructions: diff(self.instructions, base.instructions),
            cycles: diff(self.cycles, base.cycles),
            interruptWakeups: diff(self.interruptWakeups, base.interruptWakeups),
            idleWakeups: diff(self.idleWakeups, base.idleWakeups)
        )
    }

    /// Reads task_info(TASK_POWER_INFO_V2) and proc_pid_rusage(RUSAGE_INFO_V4); a failed call leaves its fields at 0.
    public static func current(date: Date = Date()) -> NanogramEnergySample {
        var sample = NanogramEnergySample(date: date)

        var power = task_power_info_v2_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<natural_t>.size)
        let powerResult = withUnsafeMutablePointer(to: &power) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        if powerResult == KERN_SUCCESS {
            sample.taskEnergyNanojoules = power.task_energy
        }

        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        if usageResult == 0 {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let nanosecondsPerTick = timebase.denom == 0 ? 1.0 : Double(timebase.numer) / Double(timebase.denom)
            sample.cpuUserSeconds = Double(usage.ri_user_time) * nanosecondsPerTick / 1e9
            sample.cpuSystemSeconds = Double(usage.ri_system_time) * nanosecondsPerTick / 1e9
            sample.billedEnergyNanojoules = usage.ri_billed_energy
            sample.instructions = usage.ri_instructions
            sample.cycles = usage.ri_cycles
            sample.interruptWakeups = usage.ri_interrupt_wkups
            sample.idleWakeups = usage.ri_pkg_idle_wkups
        }
        return sample
    }
}

public struct NanogramEnergyDelta: Equatable, Sendable {
    public var wallSeconds: Double
    public var cpuSeconds: Double
    public var billedEnergyNanojoules: UInt64
    public var taskEnergyNanojoules: UInt64
    public var instructions: UInt64
    public var cycles: UInt64
    public var interruptWakeups: UInt64
    public var idleWakeups: UInt64

    /// CPU time as a share of one core over the wall time (100 = one core busy all the time).
    public var cpuPercent: Double {
        return self.wallSeconds > 0 ? self.cpuSeconds / self.wallSeconds * 100 : 0
    }

    public var averageMilliwatts: Double? {
        let energy = self.billedEnergyNanojoules > 0 ? self.billedEnergyNanojoules : self.taskEnergyNanojoules
        guard self.wallSeconds > 0, energy > 0 else {
            return nil
        }
        return Double(energy) / 1e6 / self.wallSeconds
    }

    public func lines(indent: String = "") -> [String] {
        var lines = [
            indent + String(format: "wall time: %.0f s", self.wallSeconds),
            indent + String(format: "CPU time: %.2f s (%.1f%% of one core)", self.cpuSeconds, self.cpuPercent),
        ]
        if self.billedEnergyNanojoules > 0 {
            lines.append(indent + String(format: "billed energy: %.2f mJ", Double(self.billedEnergyNanojoules) / 1e6))
        }
        if self.taskEnergyNanojoules > 0 {
            lines.append(indent + String(format: "task energy: %.2f mJ", Double(self.taskEnergyNanojoules) / 1e6))
        }
        if let power = self.averageMilliwatts {
            lines.append(indent + String(format: "average power: %.1f mW", power))
        }
        if self.instructions > 0 {
            lines.append(indent + "instructions: \(self.instructions), cycles: \(self.cycles)")
        }
        lines.append(indent + "wakeups: \(self.interruptWakeups) interrupt, \(self.idleWakeups) package idle")
        return lines
    }
}

public struct NanogramPowerContext: Equatable, Sendable {
    public var batteryPercent: Int?
    public var isCharging: Bool?
    public var onACPower: Bool?
    public var minutesToEmpty: Int?
    public var thermalState: String
    public var lowPowerMode: Bool?

    public init(batteryPercent: Int?, isCharging: Bool?, onACPower: Bool?, minutesToEmpty: Int?, thermalState: String, lowPowerMode: Bool?) {
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.onACPower = onACPower
        self.minutesToEmpty = minutesToEmpty
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
    }

    public static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    public static func current() -> NanogramPowerContext {
        var percent: Int?
        var charging: Bool?
        var onAC: Bool?
        var minutes: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any], (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else {
                    continue
                }
                if let current = description[kIOPSCurrentCapacityKey] as? Int, let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                    percent = current * 100 / maximum
                }
                charging = description[kIOPSIsChargingKey] as? Bool
                onAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                if let value = description[kIOPSTimeToEmptyKey] as? Int, value >= 0 {
                    minutes = value
                }
            }
        }
        var lowPower: Bool?
        if #available(macOS 12.0, *) {
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        return NanogramPowerContext(batteryPercent: percent, isCharging: charging, onACPower: onAC, minutesToEmpty: minutes, thermalState: thermalName(ProcessInfo.processInfo.thermalState), lowPowerMode: lowPower)
    }

    public func lines() -> [String] {
        var lines: [String] = []
        if let percent = self.batteryPercent {
            lines.append("battery: \(percent)%" + (self.isCharging == true ? ", charging" : "") + (self.minutesToEmpty.map { ", about \($0) min left" } ?? ""))
        } else {
            lines.append("battery: none (desktop Mac or not readable)")
        }
        if let onAC = self.onACPower {
            lines.append("power source: " + (onAC ? "adapter" : "battery"))
        }
        if let lowPower = self.lowPowerMode {
            lines.append("Low Power Mode: " + (lowPower ? "on" : "off"))
        }
        lines.append("thermal state: \(self.thermalState)")
        return lines
    }
}

/// Counters since launch, and per experiment since its switch last changed, so two settings compare directly.
public final class NanogramEnergyLedger: @unchecked Sendable {
    public static let shared = NanogramEnergyLedger()

    private let sampler: @Sendable () -> NanogramEnergySample
    private let lock = NSLock()
    private let launch: NanogramEnergySample
    private var baselines: [String: NanogramEnergySample] = [:]

    public init(sampler: @escaping @Sendable () -> NanogramEnergySample = { NanogramEnergySample.current() }) {
        self.sampler = sampler
        self.launch = sampler()
    }

    public func reset(_ id: String) {
        let now = self.sampler()
        self.lock.lock()
        self.baselines[id] = now
        self.lock.unlock()
    }

    func baseline(_ id: String) -> NanogramEnergySample {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.baselines[id] ?? self.launch
    }

    /// One line for a settings row: CPU, average power and how long the window has run, since the switch last changed.
    public func summary(for id: String) -> String {
        let delta = self.sampler().since(self.baseline(id))
        var parts = [String(format: "CPU %.1f%%", delta.cpuPercent)]
        if let power = delta.averageMilliwatts {
            parts.append(String(format: "%.0f mW", power))
        }
        let seconds = Int(delta.wallSeconds)
        parts.append(seconds >= 3600 ? "over \(seconds / 3600) h \(seconds % 3600 / 60) min" : "over \(max(seconds / 60, 0)) min")
        return parts.joined(separator: ", ")
    }

    public func report(experiments: [(id: String, title: String, value: String)], power: NanogramPowerContext) -> String {
        let now = self.sampler()
        var lines = ["Energy and CPU of this app (kernel counters of the process)", ""]
        lines.append("Since launch")
        lines.append(contentsOf: now.since(self.launch).lines(indent: "  "))
        lines.append("")
        lines.append("Machine")
        lines.append(contentsOf: power.lines().map { "  " + $0 })
        lines.append("")
        if experiments.isEmpty {
            lines.append("No experiment switches are registered in this build.")
        } else {
            lines.append("Experiments, since each switch last changed (or since launch)")
            if power.onACPower == true {
                lines.append("  On adapter power: energy numbers stay valid, battery percent is not comparable.")
            }
            for experiment in experiments.sorted(by: { $0.id < $1.id }) {
                lines.append("  \(experiment.id) = \(experiment.value) (\(experiment.title))")
                lines.append(contentsOf: now.since(self.baseline(experiment.id)).lines(indent: "    "))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
