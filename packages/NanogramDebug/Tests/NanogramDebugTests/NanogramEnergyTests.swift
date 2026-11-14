import XCTest
@testable import NanogramDebug
@testable import NanogramDebugUI
@testable import NanogramLogExport

final class NanogramEnergyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func sample(_ seconds: Double, cpu: Double, billed: UInt64 = 0, wakeups: UInt64 = 0) -> NanogramEnergySample {
        return NanogramEnergySample(date: start.addingTimeInterval(seconds), cpuUserSeconds: cpu * 0.75, cpuSystemSeconds: cpu * 0.25, billedEnergyNanojoules: billed, interruptWakeups: wakeups)
    }

    func testDeltaIsTheDifferenceAndNeverNegative() {
        let delta = sample(60, cpu: 6, billed: 120_000_000, wakeups: 50).since(sample(0, cpu: 1, billed: 20_000_000, wakeups: 10))
        XCTAssertEqual(delta.wallSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(delta.cpuSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(delta.cpuPercent, 5.0 / 60 * 100, accuracy: 0.001)
        XCTAssertEqual(delta.billedEnergyNanojoules, 100_000_000)
        XCTAssertEqual(delta.averageMilliwatts ?? 0, 100.0 / 60, accuracy: 0.001)
        XCTAssertEqual(delta.interruptWakeups, 40)
        let backwards = sample(0, cpu: 0).since(sample(10, cpu: 5, billed: 5))
        XCTAssertEqual(backwards.wallSeconds, 0)
        XCTAssertEqual(backwards.cpuSeconds, 0)
        XCTAssertEqual(backwards.billedEnergyNanojoules, 0)
        XCTAssertNil(backwards.averageMilliwatts)
    }

    func testLedgerMeasuresFromTheLastChange() {
        let clock = Box(sample(0, cpu: 0))
        let ledger = NanogramEnergyLedger(sampler: { clock.value })
        clock.value = sample(100, cpu: 10)
        ledger.reset("exp.a")
        clock.value = sample(160, cpu: 16)
        let power = NanogramPowerContext(batteryPercent: 80, isCharging: false, onACPower: false, minutesToEmpty: nil, thermalState: "nominal", lowPowerMode: false)
        let text = ledger.report(experiments: [("exp.a", "A", "on"), ("exp.b", "B", "off")], power: power)
        XCTAssertTrue(text.contains("exp.a = on (A)\n    wall time: 60 s\n    CPU time: 6.00 s"), text)
        XCTAssertTrue(text.contains("exp.b = off (B)\n    wall time: 160 s\n    CPU time: 16.00 s"), text)
        XCTAssertTrue(text.contains("battery: 80%"), text)
        XCTAssertTrue(text.contains("thermal state: nominal"), text)
        XCTAssertFalse(text.contains("adapter power"), text)
    }

    func testSummaryLineCoversTheWindowSinceTheChange() {
        let clock = Box(sample(0, cpu: 0))
        let ledger = NanogramEnergyLedger(sampler: { clock.value })
        clock.value = sample(100, cpu: 10, billed: 0)
        ledger.reset("exp.a")
        clock.value = sample(220, cpu: 16, billed: 600_000_000)
        XCTAssertEqual(ledger.summary(for: "exp.a"), "CPU 5.0%, 5 mW, over 2 min")
        XCTAssertEqual(ledger.summary(for: "exp.b"), "CPU 7.3%, 3 mW, over 3 min")
    }

    func testReportWithoutExperimentsAndOnAdapter() {
        let ledger = NanogramEnergyLedger(sampler: { self.sample(0, cpu: 0) })
        let none = ledger.report(experiments: [], power: NanogramPowerContext(batteryPercent: nil, isCharging: nil, onACPower: nil, minutesToEmpty: nil, thermalState: "fair", lowPowerMode: nil))
        XCTAssertTrue(none.contains("No experiment switches are registered"), none)
        XCTAssertTrue(none.contains("battery: none"), none)
        let ac = ledger.report(experiments: [("a", "A", "on")], power: NanogramPowerContext(batteryPercent: 100, isCharging: false, onACPower: true, minutesToEmpty: nil, thermalState: "nominal", lowPowerMode: true))
        XCTAssertTrue(ac.contains("On adapter power"), ac)
        XCTAssertTrue(ac.contains("Low Power Mode: on"), ac)
    }

    func testChangingASwitchRestartsItsWindow() {
        let defaults = UserDefaults(suiteName: "NanogramEnergyTests.\(UUID().uuidString)")!
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(.toggle(id: "exp.a", section: "Media", title: "A", defaultValue: false))
        let clock = Box(sample(0, cpu: 0))
        let ledger = NanogramEnergyLedger(sampler: { clock.value })
        NanogramExperimentEnergy.install(settings: settings, ledger: ledger)
        clock.value = sample(30, cpu: 3)
        settings.set("exp.a", bool: true)
        clock.value = sample(40, cpu: 4)
        let text = NanogramExperimentEnergy.reportText(settings: settings, ledger: ledger, power: NanogramPowerContext(batteryPercent: nil, isCharging: nil, onACPower: nil, minutesToEmpty: nil, thermalState: "nominal", lowPowerMode: nil))
        XCTAssertTrue(text.contains("exp.a = on (A)\n    wall time: 10 s"), text)
    }

    func testLiveCountersAreReadable() {
        let first = NanogramEnergySample.current()
        var burn = 0
        for index in 0..<2_000_000 {
            burn &+= index
        }
        XCTAssertGreaterThan(burn, 0)
        let delta = NanogramEnergySample.current().since(first)
        XCTAssertGreaterThanOrEqual(delta.cpuSeconds, 0)
        XCTAssertFalse(NanogramPowerContext.current().thermalState.isEmpty)
    }

    func testReportStagesTheEnergyFileAndListsItInTheReadme() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NanogramEnergyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = NanogramReportDevice(model: "Mac", chip: "M", systemVersion: "1", appVersion: "1", buildNumber: "1")
        let staged = try NanogramReport.stage(device: device, sections: [], settings: [], extraFiles: [(NanogramReport.energyFileName, "cpu\n")], in: root)
        XCTAssertEqual(try String(contentsOf: staged.appendingPathComponent("energy.txt")), "cpu\n")
        XCTAssertTrue(try String(contentsOf: staged.appendingPathComponent("README.txt")).contains("- energy.txt"))
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T

    init(_ value: T) {
        self.value = value
    }
}
