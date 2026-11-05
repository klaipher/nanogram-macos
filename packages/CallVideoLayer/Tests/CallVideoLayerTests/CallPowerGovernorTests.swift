import XCTest
import NanogramDebug
import SwiftSignalKit
@testable import CallVideoLayer

private final class FakeEnvironment {
    var inputs = CallPowerInputs(thermalState: .nominal, isLowPowerModeEnabled: false)
    var time: TimeInterval = 1000
    var scheduled: [(delay: TimeInterval, work: () -> Void, cancelled: Bool)] = []
    var appliedLevels: [Int] = []
    var logs: [String] = []
    let center = NotificationCenter()

    func makeGovernor() -> CallPowerGovernor {
        return CallPowerGovernor(readInputs: { self.inputs }, now: { self.time }, schedule: { delay, work in
            let index = self.scheduled.count
            self.scheduled.append((delay, work, false))
            return { self.scheduled[index].cancelled = true }
        }, applyThermalLevel: { self.appliedLevels.append($0) }, log: { self.logs.append($0) }, notificationCenter: self.center)
    }

    func fireLiveTimers() {
        for index in self.scheduled.indices where !self.scheduled[index].cancelled {
            self.scheduled[index].cancelled = true
            self.scheduled[index].work()
        }
    }
}

final class CallPowerGovernorTests: XCTestCase {
    func testStepMapping() {
        XCTAssertEqual(CallPowerPolicy.step(for: CallPowerInputs(thermalState: .nominal, isLowPowerModeEnabled: false)), .nominal)
        XCTAssertEqual(CallPowerPolicy.step(for: CallPowerInputs(thermalState: .fair, isLowPowerModeEnabled: false)), .fair)
        XCTAssertEqual(CallPowerPolicy.step(for: CallPowerInputs(thermalState: .serious, isLowPowerModeEnabled: false)), .serious)
        XCTAssertEqual(CallPowerPolicy.step(for: CallPowerInputs(thermalState: .critical, isLowPowerModeEnabled: false)), .critical)
        XCTAssertEqual(CallPowerPolicy.step(for: CallPowerInputs(thermalState: .nominal, isLowPowerModeEnabled: true)), .fair)
    }

    func testProfileByMode() {
        XCTAssertEqual(CallPowerPolicy.profile(step: .critical, mode: .off), .full)
        XCTAssertEqual(CallPowerPolicy.profile(step: .nominal, mode: .uiAndVideo), .full)
        XCTAssertEqual(CallPowerPolicy.profile(step: .fair, mode: .ui), CallPowerProfile(reducedEffects: true, maxShortSide: 0, maxFps: 0))
        XCTAssertEqual(CallPowerPolicy.profile(step: .critical, mode: .ui), CallPowerProfile(reducedEffects: true, maxShortSide: 0, maxFps: 0))
        XCTAssertEqual(CallPowerPolicy.profile(step: .fair, mode: .uiAndVideo), CallPowerProfile(reducedEffects: true, maxShortSide: 0, maxFps: 0))
        XCTAssertEqual(CallPowerPolicy.profile(step: .serious, mode: .uiAndVideo), CallPowerProfile(reducedEffects: true, maxShortSide: 540, maxFps: 20))
        XCTAssertEqual(CallPowerPolicy.profile(step: .critical, mode: .uiAndVideo), CallPowerProfile(reducedEffects: true, maxShortSide: 360, maxFps: 15))
    }

    func testHysteresisStepsDownAtOnceAndRestoresAfterThirtySeconds() {
        var hysteresis = CallPowerHysteresis()
        XCTAssertEqual(hysteresis.update(target: .serious, now: 0), .serious)
        XCTAssertNil(hysteresis.update(target: .nominal, now: 1))
        XCTAssertNil(hysteresis.update(target: .nominal, now: 29))
        XCTAssertEqual(hysteresis.step, .serious)
        XCTAssertEqual(hysteresis.update(target: .nominal, now: 31), .nominal)
        XCTAssertFalse(hysteresis.isRestorePending)
    }

    func testRelapseCancelsRestore() {
        var hysteresis = CallPowerHysteresis()
        _ = hysteresis.update(target: .serious, now: 0)
        _ = hysteresis.update(target: .nominal, now: 1)
        XCTAssertNil(hysteresis.update(target: .serious, now: 20))
        XCTAssertFalse(hysteresis.isRestorePending)
        XCTAssertNil(hysteresis.update(target: .nominal, now: 35))
        XCTAssertEqual(hysteresis.step, .serious)
        XCTAssertEqual(hysteresis.update(target: .nominal, now: 66), .nominal)
    }

    func testRestoreUsesHighestTargetSeenInTheWindow() {
        var hysteresis = CallPowerHysteresis()
        _ = hysteresis.update(target: .critical, now: 0)
        _ = hysteresis.update(target: .nominal, now: 1)
        _ = hysteresis.update(target: .fair, now: 10)
        XCTAssertEqual(hysteresis.update(target: .nominal, now: 40), .fair)
    }

    func testRestoreKeepsGoingWhenTheRealStateIsLowerThanTheRestoredStep() {
        var hysteresis = CallPowerHysteresis()
        XCTAssertEqual(hysteresis.update(target: .critical, now: 0), .critical)
        XCTAssertNil(hysteresis.update(target: .serious, now: 1))
        XCTAssertNil(hysteresis.update(target: .nominal, now: 2))
        XCTAssertEqual(hysteresis.update(target: .nominal, now: 31), .serious)
        XCTAssertTrue(hysteresis.isRestorePending)
        XCTAssertNil(hysteresis.update(target: .nominal, now: 60))
        XCTAssertEqual(hysteresis.update(target: .nominal, now: 61), .nominal)
        XCTAssertFalse(hysteresis.isRestorePending)
    }

    func testGovernorWalksCriticalSeriousNominalWithoutExtraNotifications() {
        let environment = FakeEnvironment()
        let governor = environment.makeGovernor()
        governor.start(mode: .uiAndVideo)
        environment.inputs = CallPowerInputs(thermalState: .critical, isLowPowerModeEnabled: false)
        governor.refresh()
        environment.time += 1
        environment.inputs = CallPowerInputs(thermalState: .serious, isLowPowerModeEnabled: false)
        governor.refresh()
        environment.time += 1
        environment.inputs = CallPowerInputs(thermalState: .nominal, isLowPowerModeEnabled: false)
        governor.refresh()
        XCTAssertEqual(governor.step, .critical)

        environment.time += 30
        environment.fireLiveTimers()
        XCTAssertEqual(governor.step, .serious)
        XCTAssertEqual(environment.scheduled.filter { !$0.cancelled }.count, 1)

        environment.time += 30
        environment.fireLiveTimers()
        XCTAssertEqual(governor.step, .nominal)
        XCTAssertEqual(governor.profile, .full)
    }

    func testGovernorAppliesVideoLimitOnlyInVideoMode() {
        let environment = FakeEnvironment()
        let governor = environment.makeGovernor()
        governor.start(mode: .ui)
        environment.inputs = CallPowerInputs(thermalState: .serious, isLowPowerModeEnabled: false)
        governor.refresh()
        XCTAssertEqual(governor.step, .serious)
        XCTAssertTrue(governor.profile.reducedEffects)
        XCTAssertTrue(environment.appliedLevels.allSatisfy { $0 == 0 })

        governor.setMode(.uiAndVideo)
        XCTAssertEqual(environment.appliedLevels.last, 2)
        XCTAssertFalse(environment.logs.isEmpty)

        governor.setMode(.off)
        XCTAssertEqual(environment.appliedLevels.last, 0)
    }

    func testGovernorRestoresAfterTimerFires() {
        let environment = FakeEnvironment()
        let governor = environment.makeGovernor()
        governor.start(mode: .uiAndVideo)
        environment.inputs = CallPowerInputs(thermalState: .critical, isLowPowerModeEnabled: false)
        governor.refresh()
        XCTAssertEqual(environment.appliedLevels.last, 3)

        environment.inputs = CallPowerInputs(thermalState: .nominal, isLowPowerModeEnabled: false)
        governor.refresh()
        XCTAssertEqual(governor.step, .critical)
        XCTAssertEqual(environment.scheduled.filter { !$0.cancelled }.count, 1)
        XCTAssertEqual(environment.scheduled.last?.delay, CallPowerHysteresis.restoreDelay)

        environment.time += 31
        environment.fireLiveTimers()
        XCTAssertEqual(governor.step, .nominal)
        XCTAssertEqual(governor.profile, .full)
        XCTAssertEqual(environment.appliedLevels.last, 0)
    }

    func testNotificationRefreshesGovernor() {
        let environment = FakeEnvironment()
        let governor = environment.makeGovernor()
        governor.start(mode: .ui)
        environment.inputs = CallPowerInputs(thermalState: .fair, isLowPowerModeEnabled: false)
        environment.center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        let expectation = self.expectation(description: "main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        self.wait(for: [expectation], timeout: 2)
        XCTAssertEqual(governor.step, .fair)
    }

    func testListenersGetCurrentAndUpdatedProfileAndTokenInvalidates() {
        let environment = FakeEnvironment()
        let governor = environment.makeGovernor()
        governor.start(mode: .ui)
        var seen: [CallPowerProfile] = []
        let token = governor.observe({ seen.append($0) })
        XCTAssertEqual(seen, [.full])
        environment.inputs = CallPowerInputs(thermalState: .fair, isLowPowerModeEnabled: false)
        governor.refresh()
        XCTAssertEqual(seen.count, 2)
        token.invalidate()
        XCTAssertEqual(governor.listenerCount, 0)
        environment.inputs = CallPowerInputs(thermalState: .critical, isLowPowerModeEnabled: false)
        governor.refresh()
        XCTAssertEqual(seen.count, 2)
    }

    func testTeardownReleasesGovernorListenersAndTimers() {
        let environment = FakeEnvironment()
        weak var weakGovernor: CallPowerGovernor?
        var token: CallPowerGovernor.Token?
        autoreleasepool {
            let governor = environment.makeGovernor()
            weakGovernor = governor
            governor.start(mode: .uiAndVideo)
            token = governor.observe({ _ in })
            environment.inputs = CallPowerInputs(thermalState: .serious, isLowPowerModeEnabled: false)
            governor.refresh()
            environment.inputs = CallPowerInputs(thermalState: .nominal, isLowPowerModeEnabled: false)
            governor.refresh()
        }
        XCTAssertNil(weakGovernor)
        XCTAssertTrue(environment.scheduled.allSatisfy { $0.cancelled })
        token?.invalidate()
        let limitsBefore = environment.appliedLevels.count
        environment.center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(environment.appliedLevels.count, limitsBefore)
    }

    func testLadderModeParsing() {
        XCTAssertEqual(CallThermalLadderMode(choice: "off"), .off)
        XCTAssertEqual(CallThermalLadderMode(choice: "ui"), .ui)
        XCTAssertEqual(CallThermalLadderMode(choice: "uiAndVideo"), .uiAndVideo)
        XCTAssertEqual(CallThermalLadderMode(choice: "bogus"), .ui)
        XCTAssertEqual(CallThermalLadderMode(choice: nil), .ui)
    }
}

final class CallSystemPolicyTests: XCTestCase {
    private func makeSettings() -> NanogramDebugSettings {
        return NanogramDebugSettings(defaults: UserDefaults(suiteName: "CallSystemPolicyTests.\(UUID().uuidString)")!)
    }

    func testDeliveryGateAlwaysAdmitsFirstFrameThenDropsWhileSuspended() {
        let gate = VideoFrameDeliveryGate()
        gate.setSuspended(true)
        XCTAssertTrue(gate.admit())
        XCTAssertFalse(gate.admit())
        XCTAssertFalse(gate.admit())
        gate.setSuspended(false)
        XCTAssertTrue(gate.admit())
        XCTAssertTrue(gate.admit())
        gate.setSuspended(true)
        XCTAssertFalse(gate.admit())
    }

    func testDeliveryGateIsThreadSafe() {
        let gate = VideoFrameDeliveryGate()
        let group = DispatchGroup()
        for index in 0 ..< 8 {
            DispatchQueue.global().async(group: group) {
                for step in 0 ..< 2000 {
                    if index == 0 {
                        gate.setSuspended(step % 2 == 0)
                    } else {
                        _ = gate.admit()
                    }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    }

    func testBlobFrameRates() {
        XCTAssertEqual(CallAnimationFrameRate.blobFramesPerSecond(reducedEffects: false), 60)
        XCTAssertEqual(CallAnimationFrameRate.blobFramesPerSecond(reducedEffects: true), 30)
    }

    func testLivestreamSuspendOnlyForHiddenStreamWhenEnabled() {
        XCTAssertTrue(LivestreamDecodePolicy.shouldSuspendVideo(enabled: true, isStream: true, isWindowVisible: false))
        XCTAssertFalse(LivestreamDecodePolicy.shouldSuspendVideo(enabled: true, isStream: true, isWindowVisible: true))
        XCTAssertFalse(LivestreamDecodePolicy.shouldSuspendVideo(enabled: true, isStream: false, isWindowVisible: false))
        XCTAssertFalse(LivestreamDecodePolicy.shouldSuspendVideo(enabled: false, isStream: true, isWindowVisible: false))
    }

    func testStatusBarPulseStopsWhenSeriousOrWorse() {
        XCTAssertEqual(StatusBarPulsePolicy.interval(power: .nominal), 0.25)
        XCTAssertEqual(StatusBarPulsePolicy.interval(power: .fair), 0.25)
        XCTAssertNil(StatusBarPulsePolicy.interval(power: .serious))
        XCTAssertNil(StatusBarPulsePolicy.interval(power: .critical))
    }

    func testSystemOptionDefaults() {
        let settings = self.makeSettings()
        _ = CallVideoDebugOptions.install(in: settings)
        defer {
            CallPowerGovernor.shared.stop()
        }
        XCTAssertTrue(settings.bool("calls.thermalVideoLadder"))
        let ids = (CallSystemDebugOptions.all + CallAudioDebugOptions.all + CallVideoDebugOptions.all).map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testNoopVideoSourceDefaultAcceptsSuspension() {
        final class Source: VideoSource {
            var currentOutput: Output? { return nil }
            func addOnUpdated(_ f: @escaping () -> Void) -> Disposable { return EmptyDisposable }
        }
        Source().setDeliverySuspended(true)
    }
}
