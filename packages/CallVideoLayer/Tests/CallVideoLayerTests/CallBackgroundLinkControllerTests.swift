import XCTest
import NanogramDebug
@testable import CallVideoLayer

private final class FakeLink {
    let onDeinit: () -> Void

    init(onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        self.onDeinit()
    }
}

final class CallBackgroundLinkControllerTests: XCTestCase {
    private var created = 0
    private var alive = 0

    private func makeController(policy: CallBackgroundAnimationPolicy) -> CallBackgroundLinkController {
        self.created = 0
        self.alive = 0
        return CallBackgroundLinkController(policy: policy, makeLink: { _ in
            self.created += 1
            self.alive += 1
            return FakeLink(onDeinit: { self.alive -= 1 })
        }, tick: { _ in })
    }

    private func policy(inHierarchy: Bool = true, suspended: Bool = false, energy: Bool = false, optimized: Bool = true) -> CallBackgroundAnimationPolicy {
        return CallBackgroundAnimationPolicy(isInHierarchy: inHierarchy, isSuspended: suspended, isEnergySavingEnabled: energy, isIdleOptimizationEnabled: optimized)
    }

    func testNoLinkOutsideHierarchy() {
        let controller = self.makeController(policy: self.policy(inHierarchy: false))
        controller.refresh()
        XCTAssertEqual(self.alive, 0)
    }

    func testLinkRunsInHierarchy() {
        let controller = self.makeController(policy: self.policy())
        controller.refresh()
        XCTAssertEqual(self.alive, 1)
        XCTAssertTrue(controller.hasLink)
    }

    func testLinkCountIsZeroWhileVideoIsShown() {
        let controller = self.makeController(policy: self.policy())
        controller.refresh()
        controller.policy = self.policy(suspended: true)
        XCTAssertEqual(self.alive, 0)
        XCTAssertFalse(controller.hasLink)
    }

    func testLinkResumesWhenVideoGoesAway() {
        let controller = self.makeController(policy: self.policy(suspended: true))
        controller.refresh()
        XCTAssertEqual(self.alive, 0)
        controller.policy = self.policy(suspended: false)
        XCTAssertEqual(self.alive, 1)
        XCTAssertEqual(self.created, 1)
    }

    func testRepeatedPolicyUpdatesKeepOneLink() {
        let controller = self.makeController(policy: self.policy())
        controller.refresh()
        controller.policy = self.policy(energy: false)
        controller.refresh()
        controller.refresh()
        XCTAssertEqual(self.created, 1)
        XCTAssertEqual(self.alive, 1)
    }

    func testEnergySavingStopsLink() {
        let controller = self.makeController(policy: self.policy())
        controller.refresh()
        controller.policy = self.policy(energy: true)
        XCTAssertEqual(self.alive, 0)
    }

    func testLegacyModeNeverStopsForVideoOrEnergySaving() {
        let controller = self.makeController(policy: self.policy(suspended: true, energy: true, optimized: false))
        controller.refresh()
        XCTAssertEqual(self.alive, 1)
    }

    func testLeavingHierarchyStopsLinkInBothModes() {
        for optimized in [true, false] {
            let controller = self.makeController(policy: self.policy(optimized: optimized))
            controller.refresh()
            controller.policy = self.policy(inHierarchy: false, optimized: optimized)
            XCTAssertEqual(self.alive, 0)
        }
    }
}

final class CallVideoDebugOptionsTests: XCTestCase {
    private func makeSettings() -> NanogramDebugSettings {
        let suite = "CallVideoDebugOptionsTests.\(UUID().uuidString)"
        return NanogramDebugSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    func testIdsAreUniqueAndNamespaced() {
        let ids = CallVideoDebugOptions.all.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertTrue(id.hasPrefix("calls.") || id.hasPrefix("tgcalls."), id)
        }
    }

    func testDefaults() {
        let settings = self.makeSettings()
        _ = CallVideoDebugOptions.install(in: settings)
        XCTAssertTrue(settings.bool("calls.backgroundGradientIdle"))
        XCTAssertTrue(settings.bool("calls.cameraFormatV2"))
        XCTAssertFalse(settings.bool("calls.hardwareCrop"))
        XCTAssertFalse(settings.bool("calls.nativeDecodeFormat"))
        XCTAssertFalse(settings.bool("tgcalls.livestreamHardwareDecode"))
        XCTAssertFalse(settings.bool("tgcalls.screencastHardwareEncoder"))
        XCTAssertFalse(settings.bool("calls.groupVideoCap"))
        XCTAssertFalse(CallVideoDebugOptions.isGroupVideoCapEnabled(in: settings))
    }

    /// The low-latency H.264 encoder was always on in the Mac build (Q6); the switch is a kill switch, so its default keeps today.
    func testEncoderLowLatencyKillSwitchDefaultsToOn() {
        let settings = self.makeSettings()
        _ = CallVideoDebugOptions.install(in: settings)
        XCTAssertEqual(CallVideoDebugOptions.encoderLowLatency.id, "calls.encoderLowLatency")
        XCTAssertTrue(CallVideoDebugOptions.all.contains(where: { $0.id == "calls.encoderLowLatency" }))
        XCTAssertTrue(settings.bool("calls.encoderLowLatency"))
    }

    func testGroupVideoCapOverride() {
        let settings = self.makeSettings()
        let observations = CallVideoDebugOptions.install(in: settings)
        settings.set("calls.groupVideoCap", bool: true)
        XCTAssertTrue(CallVideoDebugOptions.isGroupVideoCapEnabled(in: settings))
        withExtendedLifetime(observations) {}
    }

    func testOverrideReachesSettings() {
        let settings = self.makeSettings()
        let observations = CallVideoDebugOptions.install(in: settings)
        settings.set("calls.backgroundGradientIdle", bool: false)
        XCTAssertFalse(CallVideoDebugOptions.isBackgroundGradientIdleEnabled(in: settings))
        withExtendedLifetime(observations) {}
    }
}

final class GroupVideoChannelSelectionTests: XCTestCase {
    private func candidate(_ id: String, dominant: Bool = false, screencast: Bool = false, local: Bool = false) -> GroupVideoChannelCandidate {
        return GroupVideoChannelCandidate(endpointId: id, isDominant: dominant, isScreencast: screencast, isLocal: local)
    }

    func testSmallRoomsAreUnchanged() {
        let candidates = (0 ..< 10).map { self.candidate("v\($0)") }
        XCTAssertEqual(GroupVideoChannelSelection.select(candidates), Set(candidates.map { $0.endpointId }))
    }

    func testLargeRoomsAreCapped() {
        let candidates = (0 ..< 40).map { self.candidate("v\($0)") }
        let selected = GroupVideoChannelSelection.select(candidates)
        XCTAssertEqual(selected.count, 10)
        XCTAssertTrue(selected.contains("v0"))
        XCTAssertFalse(selected.contains("v39"))
    }

    func testDominantAndScreencastAreKeptOverOrder() {
        var candidates = (0 ..< 30).map { self.candidate("v\($0)") }
        candidates.append(self.candidate("pinned", dominant: true))
        candidates.append(self.candidate("screen", screencast: true))
        let selected = GroupVideoChannelSelection.select(candidates)
        XCTAssertTrue(selected.contains("pinned"))
        XCTAssertTrue(selected.contains("screen"))
        XCTAssertEqual(selected.count, 10)
        XCTAssertFalse(selected.contains("v9"))
    }

    func testLocalChannelsNeverCountAgainstTheLimit() {
        var candidates = (0 ..< 30).map { self.candidate("v\($0)") }
        candidates.append(self.candidate("me", local: true))
        candidates.append(self.candidate("myScreen", screencast: true, local: true))
        let selected = GroupVideoChannelSelection.select(candidates)
        XCTAssertTrue(selected.contains("me"))
        XCTAssertTrue(selected.contains("myScreen"))
        XCTAssertEqual(selected.count, 12)
    }

    func testZeroLimitKeepsOnlyLocal() {
        let candidates = [self.candidate("a"), self.candidate("me", local: true)]
        XCTAssertEqual(GroupVideoChannelSelection.select(candidates, remoteLimit: 0), ["me"])
    }

    func testOrderIsStableAndEmptyInputWorks() {
        XCTAssertTrue(GroupVideoChannelSelection.select([]).isEmpty)
        let candidates = (0 ..< 12).map { self.candidate("v\($0)") }
        XCTAssertEqual(GroupVideoChannelSelection.select(candidates, remoteLimit: 3), ["v0", "v1", "v2"])
    }
}
