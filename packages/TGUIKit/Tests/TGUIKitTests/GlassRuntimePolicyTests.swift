import XCTest
@testable import TGUIKit

final class GlassRuntimePolicyTests: XCTestCase {
    private final class Listener: GlassEnvironmentListener {
        var calls = 0
        func glassEnvironmentDidChange() { calls += 1 }
    }

    func testPrefersOpaqueForReduceTransparencyOrIncreaseContrast() {
        XCTAssertFalse(GlassAccessibilityState(reduceTransparency: false, increaseContrast: false).prefersOpaque)
        XCTAssertTrue(GlassAccessibilityState(reduceTransparency: true, increaseContrast: false).prefersOpaque)
        XCTAssertTrue(GlassAccessibilityState(reduceTransparency: false, increaseContrast: true).prefersOpaque)
        XCTAssertTrue(GlassAccessibilityState(reduceTransparency: true, increaseContrast: true).prefersOpaque)
    }

    func testMonitorNotifiesListenersOnlyWhenTheStateChanges() {
        var current = GlassAccessibilityState(reduceTransparency: false, increaseContrast: false)
        let monitor = GlassAccessibilityMonitor(read: { current })
        let listener = Listener()
        monitor.register(listener)

        XCTAssertFalse(monitor.refresh())
        XCTAssertEqual(listener.calls, 0)

        current.reduceTransparency = true
        XCTAssertTrue(monitor.refresh())
        XCTAssertEqual(listener.calls, 1)
        XCTAssertTrue(monitor.state.prefersOpaque)

        XCTAssertFalse(monitor.refresh())
        XCTAssertEqual(listener.calls, 1)

        current.reduceTransparency = false
        XCTAssertTrue(monitor.refresh())
        XCTAssertEqual(listener.calls, 2)
        XCTAssertFalse(monitor.state.prefersOpaque)
    }

    func testMonitorHoldsListenersWeakly() {
        var current = GlassAccessibilityState(reduceTransparency: false, increaseContrast: false)
        let monitor = GlassAccessibilityMonitor(read: { current })
        var listener: Listener? = Listener()
        weak var weakListener = listener
        monitor.register(listener!)
        listener = nil
        XCTAssertNil(weakListener)
        current.increaseContrast = true
        XCTAssertTrue(monitor.refresh())
    }

    func testDebugParsingKnownUnknownAndAll() {
        XCTAssertEqual(GlassDebug.parse(nil), [])
        XCTAssertEqual(GlassDebug.parse(""), [])
        XCTAssertEqual(GlassDebug.parse("chatHeader,inputRow"), [.chatHeader, .inputRow])
        XCTAssertEqual(GlassDebug.parse(" tabBar , bogus ,toasts"), [.tabBar, .toasts])
        XCTAssertEqual(GlassDebug.parse("all"), Set(GlassGroup.allCases))
    }

    func testUngroupedGlassIsNeverDisabled() {
        XCTAssertFalse(GlassDebug.isDisabled(nil))
    }

    func testDisabledGroupsAreEmptyWithoutLaunchArgument() {
        XCTAssertTrue(GlassDebug.disabledGroups.isEmpty)
    }
}
