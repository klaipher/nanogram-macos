import XCTest
@testable import NanogramRuntime

final class LiteModePowerPolicyTests: XCTestCase {
    private func state(battery: Double = 100, lowPower: Bool = false, thermal: ProcessInfo.ThermalState = .nominal) -> PowerStateSnapshot {
        return PowerStateSnapshot(batteryLevel: battery, isLowPowerModeEnabled: lowPower, thermalState: thermal)
    }

    func testManualSwitchAlwaysWins() {
        XCTAssertTrue(LiteModePowerPolicy.isLite(enabled: true, lowBatteryPercent: 100, keyEnabled: true, power: state()))
    }

    func testThresholdOffIgnoresLowPowerThermalAndBattery() {
        XCTAssertFalse(LiteModePowerPolicy.isLite(enabled: false, lowBatteryPercent: 100, keyEnabled: true, power: state(battery: 5, lowPower: true, thermal: .critical)))
    }

    func testThresholdOnReactsToBatteryLowPowerAndSeriousThermal() {
        XCTAssertFalse(LiteModePowerPolicy.isLite(enabled: false, lowBatteryPercent: 20, keyEnabled: true, power: state(battery: 50)))
        XCTAssertTrue(LiteModePowerPolicy.isLite(enabled: false, lowBatteryPercent: 20, keyEnabled: true, power: state(battery: 20)))
        XCTAssertTrue(LiteModePowerPolicy.isLite(enabled: false, lowBatteryPercent: 20, keyEnabled: true, power: state(battery: 50, lowPower: true)))
        XCTAssertFalse(LiteModePowerPolicy.isLite(enabled: false, lowBatteryPercent: 20, keyEnabled: true, power: state(battery: 50, thermal: .fair)))
        XCTAssertTrue(LiteModePowerPolicy.isLite(enabled: false, lowBatteryPercent: 20, keyEnabled: true, power: state(battery: 50, thermal: .serious)))
        XCTAssertTrue(LiteModePowerPolicy.isLite(enabled: false, lowBatteryPercent: 20, keyEnabled: true, power: state(battery: 50, thermal: .critical)))
    }

    func testDisabledKeyIsLite() {
        XCTAssertTrue(LiteModePowerPolicy.isLite(enabled: false, lowBatteryPercent: 100, keyEnabled: false, power: state()))
    }
}

private final class FakePowerSource: PowerSourceObserving {
    var starts = 0
    var stops = 0
    var handler: (() -> Void)?

    func start(_ onChange: @escaping () -> Void) {
        starts += 1
        handler = onChange
    }

    func stop() {
        stops += 1
        handler = nil
    }
}

final class PowerStateMonitorTests: XCTestCase {
    private var battery: Double? = 80
    private var lowPower = false
    private var thermal: ProcessInfo.ThermalState = .nominal

    private func reading() -> PowerStateReading {
        return PowerStateReading(batteryLevel: { [unowned self] in self.battery }, isLowPowerModeEnabled: { [unowned self] in self.lowPower }, thermalState: { [unowned self] in self.thermal })
    }

    func testBatteryIsNotObservedWhileThresholdIsOff() {
        let source = FakePowerSource()
        let monitor = PowerStateMonitor(reading: reading(), batterySource: source, notificationCenter: NotificationCenter(), onChange: { _ in })
        monitor.setObservesBattery(false)
        XCTAssertEqual(source.starts, 0)
        monitor.setObservesBattery(true)
        monitor.setObservesBattery(true)
        XCTAssertEqual(source.starts, 1)
        monitor.setObservesBattery(false)
        XCTAssertEqual(source.stops, 1)
    }

    func testNoInternalBatteryMeansNoBatteryObservation() {
        battery = nil
        let source = FakePowerSource()
        let monitor = PowerStateMonitor(reading: reading(), batterySource: source, notificationCenter: NotificationCenter(), onChange: { _ in })
        monitor.setObservesBattery(true)
        XCTAssertEqual(source.starts, 0)
        XCTAssertEqual(monitor.state.batteryLevel, 100)
    }

    func testChangesAreReportedOnlyWhenTheStateChanges() {
        let source = FakePowerSource()
        let center = NotificationCenter()
        var reported: [PowerStateSnapshot] = []
        let monitor = PowerStateMonitor(reading: reading(), batterySource: source, notificationCenter: center, onChange: { reported.append($0) })
        monitor.setObservesBattery(true)
        XCTAssertEqual(reported.map { $0.batteryLevel }, [80])
        reported.removeAll()
        source.handler?()
        source.handler?()
        XCTAssertEqual(reported.count, 0)
        battery = 79
        source.handler?()
        XCTAssertEqual(reported.map { $0.batteryLevel }, [79])
        lowPower = true
        center.post(name: PowerStateMonitor.powerStateDidChangeNotification, object: nil)
        XCTAssertEqual(reported.last?.isLowPowerModeEnabled, true)
        thermal = .serious
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(reported.last?.thermalState, .serious)
        XCTAssertEqual(reported.count, 3)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(reported.count, 3)
        withExtendedLifetime(monitor) {}
    }

    func testBatteryIsReadOnlyWhileObserved() {
        let source = FakePowerSource()
        var reads = 0
        let counting = PowerStateReading(batteryLevel: { reads += 1; return 50 }, isLowPowerModeEnabled: { false }, thermalState: { .nominal })
        let monitor = PowerStateMonitor(reading: counting, batterySource: source, notificationCenter: NotificationCenter(), onChange: { _ in })
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(monitor.state.batteryLevel, 100)
        monitor.setObservesBattery(true)
        XCTAssertEqual(monitor.state.batteryLevel, 50)
        monitor.setObservesBattery(false)
        XCTAssertEqual(monitor.state.batteryLevel, 100)
    }
}
