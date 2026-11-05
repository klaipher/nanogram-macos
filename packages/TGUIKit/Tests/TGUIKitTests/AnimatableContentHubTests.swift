import XCTest
import AppKit
@testable import TGUIKit

private final class HubCountingTarget: NSObject {
    var calls = 0
    @objc func update() {
        calls += 1
    }
}

final class AnimatableContentHubTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
    }

    private func makeScrollHierarchy() -> (NSWindow, NSScrollView, [NSView]) {
        let window = NSWindow(contentRect: NSMakeRect(0, 0, 300, 300), styleMask: [.titled], backing: .buffered, defer: true)
        let scrollView = NSScrollView(frame: NSMakeRect(0, 0, 300, 300))
        let document = NSView(frame: NSMakeRect(0, 0, 300, 3000))
        scrollView.documentView = document
        window.contentView = scrollView
        var rows: [NSView] = []
        for index in 0..<50 {
            let row = NSView(frame: NSMakeRect(0, CGFloat(index) * 40, 300, 40))
            document.addSubview(row)
            rows.append(row)
        }
        return (window, scrollView, rows)
    }

    func testManyObserversOnOneScrollViewShareTheCenterObservers() {
        let baseline = AnimatableContentHub.shared.centerObserverCount
        let (window, _, rows) = makeScrollHierarchy()
        var observers: [AnimatableContentObserver] = []
        var targets: [HubCountingTarget] = []
        for row in rows {
            let target = HubCountingTarget()
            let observer = AnimatableContentObserver()
            observer.update(for: row, target: target, selector: #selector(HubCountingTarget.update))
            observers.append(observer)
            targets.append(target)
        }
        // key, resign, occlusion, hide, unhide, playback visibility, content bounds, document frame
        XCTAssertEqual(AnimatableContentHub.shared.centerObserverCount - baseline, 8)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(targets.allSatisfy { $0.calls == 1 })

        observers.removeAll()
        targets.removeAll()
        XCTAssertEqual(AnimatableContentHub.shared.centerObserverCount, baseline)
    }

    func testScrollNotificationReachesEveryListenerOnceAndOnlyOnItsSource() throws {
        let (_, scrollView, rows) = makeScrollHierarchy()
        let first = HubCountingTarget()
        let second = HubCountingTarget()
        let firstObserver = AnimatableContentObserver()
        let secondObserver = AnimatableContentObserver()
        firstObserver.update(for: rows[0], target: first, selector: #selector(HubCountingTarget.update))
        secondObserver.update(for: rows[1], target: second, selector: #selector(HubCountingTarget.update))

        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(second.calls, 1)

        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: NSView())
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(second.calls, 1)
        withExtendedLifetime((firstObserver, secondObserver)) {}
    }

    func testDeallocatedObserverStopsReceivingAndOthersKeepWorking() {
        let (_, scrollView, rows) = makeScrollHierarchy()
        let keeper = HubCountingTarget()
        let keeperObserver = AnimatableContentObserver()
        keeperObserver.update(for: rows[0], target: keeper, selector: #selector(HubCountingTarget.update))
        let gone = HubCountingTarget()
        var goneObserver: AnimatableContentObserver? = AnimatableContentObserver()
        goneObserver?.update(for: rows[1], target: gone, selector: #selector(HubCountingTarget.update))

        goneObserver = nil
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        XCTAssertEqual(keeper.calls, 1)
        XCTAssertEqual(gone.calls, 0)
        withExtendedLifetime(keeperObserver) {}
    }

    func testReupdatingWithTheSameViewDoesNotDuplicateDelivery() {
        let (_, scrollView, rows) = makeScrollHierarchy()
        let target = HubCountingTarget()
        let observer = AnimatableContentObserver()
        for _ in 0..<5 {
            observer.update(for: rows[0], target: target, selector: #selector(HubCountingTarget.update))
        }
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        XCTAssertEqual(target.calls, 1)
        withExtendedLifetime(observer) {}
    }

    func testTokenObserverDeliversThroughTheHubAndStopsAfterRemoval() {
        let (window, _, rows) = makeScrollHierarchy()
        var calls = 0
        let observer = AnimatableContentTokenObserver()
        observer.update(for: rows[0], handler: { _ in calls += 1 })
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(calls, 1)
        observer.removeObservers()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(calls, 1)
    }

    func testListenerMayUnsubscribeWhileBeingNotified() {
        let hub = AnimatableContentHub.shared
        let name = Notification.Name("AnimatableContentHubTests.reentrant")
        let source = NSObject()
        var calls = 0
        var subscription: AnimatableContentHub.Subscription?
        subscription = hub.subscribe(name: name, object: source, handler: { _ in
            calls += 1
            if let subscription { hub.unsubscribe(subscription) }
        })
        NotificationCenter.default.post(name: name, object: source)
        NotificationCenter.default.post(name: name, object: source)
        XCTAssertEqual(calls, 1)
    }
}
