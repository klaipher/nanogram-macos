import XCTest
import AppKit
@testable import TGUIKit

private final class PlaybackCountingTarget: NSObject {
    var calls = 0
    @objc func update() {
        calls += 1
    }
}

final class PlaybackVisibilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
    }

    override func tearDown() {
        PlaybackVisibility.setScreenAvailable(true)
        super.tearDown()
    }

    func testPlaybackNeedsAKeyVisibleWindowAShownAppAndAnAwakeUnlockedScreen() {
        XCTAssertTrue(PlaybackVisibility.isVisible(isKeyWindow: true, isWindowVisible: true, isAppHidden: false, isScreenAvailable: true))
        XCTAssertFalse(PlaybackVisibility.isVisible(isKeyWindow: false, isWindowVisible: true, isAppHidden: false, isScreenAvailable: true))
        XCTAssertFalse(PlaybackVisibility.isVisible(isKeyWindow: true, isWindowVisible: false, isAppHidden: false, isScreenAvailable: true))
        XCTAssertFalse(PlaybackVisibility.isVisible(isKeyWindow: true, isWindowVisible: true, isAppHidden: true, isScreenAvailable: true))
        XCTAssertFalse(PlaybackVisibility.isVisible(isKeyWindow: true, isWindowVisible: true, isAppHidden: false, isScreenAvailable: false))
    }

    func testAViewWithoutAWindowIsNotPlaybackVisible() {
        XCTAssertFalse(NSView(frame: NSMakeRect(0, 0, 10, 10)).isPlaybackVisible)
    }

    func testObserversReevaluateOnOcclusionHideAndScreenChanges() {
        let window = NSWindow(contentRect: NSMakeRect(0, 0, 300, 300), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: NSMakeRect(0, 0, 300, 300))
        window.contentView = root
        let observed = NSView(frame: NSMakeRect(0, 0, 20, 20))
        root.addSubview(observed)

        let target = PlaybackCountingTarget()
        let observer = AnimatableContentObserver()
        observer.update(for: observed, target: target, selector: #selector(PlaybackCountingTarget.update))

        var tokenCalls = 0
        let tokenObserver = AnimatableContentTokenObserver()
        tokenObserver.update(for: observed, handler: { _ in tokenCalls += 1 })

        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(target.calls, 1)
        XCTAssertEqual(tokenCalls, 1)
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: NSApp)
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: NSApp)
        XCTAssertEqual(target.calls, 3)
        XCTAssertEqual(tokenCalls, 3)
        PlaybackVisibility.setScreenAvailable(false)
        XCTAssertEqual(target.calls, 4)
        XCTAssertEqual(tokenCalls, 4)
        PlaybackVisibility.setScreenAvailable(false)
        XCTAssertEqual(target.calls, 4)
        XCTAssertFalse(observed.isPlaybackVisible)

        let otherWindow = NSWindow(contentRect: NSMakeRect(0, 0, 100, 100), styleMask: [.titled], backing: .buffered, defer: true)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: otherWindow)
        XCTAssertEqual(target.calls, 4)
        withExtendedLifetime(observer) {}
        withExtendedLifetime(tokenObserver) {}
    }
}
