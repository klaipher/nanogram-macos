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
            XCTAssertTrue(id.hasPrefix("calls."), id)
        }
    }

    func testDefaults() {
        let settings = self.makeSettings()
        _ = CallVideoDebugOptions.install(in: settings)
        XCTAssertTrue(settings.bool("calls.hardwareCrop"))
        XCTAssertTrue(settings.bool("calls.nativeDecodeFormat"))
        XCTAssertTrue(settings.bool("calls.livestreamHardwareDecoding"))
        XCTAssertTrue(settings.bool("calls.screencastHardwareEncoder"))
        XCTAssertTrue(settings.bool("calls.groupVideoCap"))
        XCTAssertTrue(settings.bool("calls.thermalVideoLadder"))
        XCTAssertTrue(CallVideoDebugOptions.isGroupVideoCapEnabled(in: settings))
    }

    func testInstallWithNothingStoredTakesTheNewDefaults() {
        let settings = self.makeSettings()
        let ids = ["calls.hardwareCrop", "calls.nativeDecodeFormat", "calls.livestreamHardwareDecoding", "calls.screencastHardwareEncoder", "calls.groupVideoCap", "calls.thermalVideoLadder"]
        for id in ids {
            XCTAssertFalse(settings.isOverridden(id), id)
        }
        _ = CallVideoDebugOptions.install(in: settings)
        for id in ids {
            XCTAssertTrue(settings.bool(id), id)
            XCTAssertFalse(settings.isOverridden(id), id)
        }
        XCTAssertEqual(settings.choice("calls.groupNoiseMode"), "rnnoise")
    }

    func testAnExplicitOffChoiceIsKept() {
        let settings = self.makeSettings()
        settings.set("calls.hardwareCrop", bool: false)
        settings.set("calls.groupNoiseMode", choice: "both")
        _ = CallVideoDebugOptions.install(in: settings)
        XCTAssertFalse(settings.bool("calls.hardwareCrop"))
        XCTAssertEqual(settings.choice("calls.groupNoiseMode"), "both")
    }

    func testDefaultOnOptionsCanBeSwitchedOffAndReset() {
        let settings = self.makeSettings()
        let observations = CallVideoDebugOptions.install(in: settings)
        settings.set("calls.groupVideoCap", bool: false)
        XCTAssertFalse(CallVideoDebugOptions.isGroupVideoCapEnabled(in: settings))
        settings.reset("calls.groupVideoCap")
        XCTAssertTrue(CallVideoDebugOptions.isGroupVideoCapEnabled(in: settings))
        withExtendedLifetime(observations) {}
    }

    func testDetailsNameTheCurrentDefault() {
        for option in CallVideoDebugOptions.all + CallSystemDebugOptions.all {
            XCTAssertTrue(option.detail?.contains("Default: on.") ?? false, option.id)
            XCTAssertFalse(option.detail?.contains("Default: off.") ?? true, option.id)
        }
        XCTAssertTrue(CallAudioDebugOptions.groupNoiseMode.detail?.contains("Default: RNNoise only.") ?? false)
    }

    func testGroupVideoCapOverride() {
        let settings = self.makeSettings()
        let observations = CallVideoDebugOptions.install(in: settings)
        settings.set("calls.groupVideoCap", bool: false)
        XCTAssertFalse(CallVideoDebugOptions.isGroupVideoCapEnabled(in: settings))
        withExtendedLifetime(observations) {}
    }

    func testSectionIsStreamsAndCalls() {
        XCTAssertEqual(CallVideoDebugOptions.section, "Streams & Calls")
        for option in CallVideoDebugOptions.all + CallAudioDebugOptions.all + CallSystemDebugOptions.all {
            XCTAssertEqual(option.section, "Streams & Calls", option.id)
            XCTAssertNotNil(option.detail, option.id)
            XCTAssertTrue(option.detail?.contains("Default:") ?? false, option.id)
        }
    }

    func testStoredValuesOfRenamedAndMergedOptionsMigrate() {
        let settings = self.makeSettings()
        settings.set("tgcalls.livestreamHardwareDecode", bool: true)
        settings.set("tgcalls.screencastHardwareEncoder", bool: true)
        settings.set("calls.thermalLadder", choice: "uiAndVideo")
        _ = CallVideoDebugOptions.install(in: settings)
        XCTAssertTrue(settings.bool("calls.livestreamHardwareDecoding"))
        XCTAssertTrue(settings.bool("calls.screencastHardwareEncoder"))
        XCTAssertTrue(settings.bool("calls.thermalVideoLadder"))
        XCTAssertFalse(settings.isOverridden("tgcalls.livestreamHardwareDecode"))
        XCTAssertFalse(settings.isOverridden("calls.thermalLadder"))
    }

    func testStoredOffThermalLadderStaysOff() {
        let settings = self.makeSettings()
        settings.set("calls.thermalLadder", choice: "ui")
        _ = CallVideoDebugOptions.install(in: settings)
        XCTAssertFalse(settings.bool("calls.thermalVideoLadder"))
    }

    func testOverrideReachesSettings() {
        let settings = self.makeSettings()
        let observations = CallVideoDebugOptions.install(in: settings)
        settings.set("calls.hardwareCrop", bool: false)
        XCTAssertFalse(settings.bool("calls.hardwareCrop"))
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

    func testVisibleTilesAreNeverDroppedByTheCap() {
        let candidates = (0 ..< 30).map { GroupVideoChannelCandidate(endpointId: "v\($0)", isDominant: false, isScreencast: false, isLocal: false, isVisible: $0 >= 5 && $0 < 17) }
        let selected = GroupVideoChannelSelection.select(candidates)
        XCTAssertEqual(selected, Set((5 ..< 17).map { "v\($0)" }))
    }

    func testVisibleTilesComeBeforeOffscreenOnesWhenThereIsRoom() {
        let candidates = (0 ..< 30).map { GroupVideoChannelCandidate(endpointId: "v\($0)", isDominant: false, isScreencast: false, isLocal: false, isVisible: $0 >= 20 && $0 < 23) }
        let selected = GroupVideoChannelSelection.select(candidates)
        XCTAssertEqual(selected.count, 10)
        XCTAssertTrue(selected.isSuperset(of: ["v20", "v21", "v22", "v0", "v6"]))
        XCTAssertFalse(selected.contains("v7"))
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
