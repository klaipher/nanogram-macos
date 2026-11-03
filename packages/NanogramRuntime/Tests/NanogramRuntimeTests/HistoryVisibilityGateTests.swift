import AppKit
import XCTest
@testable import NanogramRuntime

final class HistoryVisibilityGateTests: XCTestCase {
    func testVisibleAlwaysApplies() {
        XCTAssertTrue(HistoryVisibilityGate.shouldApply(visible: true, isPlainGenericUpdate: true, hasScrollPosition: false, appliedOnce: true))
    }

    func testHiddenSkipsOnlyPlainGenericUpdatesWithoutScroll() {
        XCTAssertFalse(HistoryVisibilityGate.shouldApply(visible: false, isPlainGenericUpdate: true, hasScrollPosition: false, appliedOnce: true))
        XCTAssertTrue(HistoryVisibilityGate.shouldApply(visible: false, isPlainGenericUpdate: true, hasScrollPosition: true, appliedOnce: true))
        XCTAssertTrue(HistoryVisibilityGate.shouldApply(visible: false, isPlainGenericUpdate: false, hasScrollPosition: false, appliedOnce: true))
    }

    func testHiddenNeverSkipsBeforeTheFirstTransition() {
        XCTAssertTrue(HistoryVisibilityGate.shouldApply(visible: false, isPlainGenericUpdate: true, hasScrollPosition: false, appliedOnce: false))
    }

    func testHiddenUpdatesCollapseIntoOneDiffOnReveal() {
        var visible = true
        var previous: [Int] = []
        var applied: [[Int]] = []
        var prepared = 0
        func emit(_ view: [Int]) {
            guard HistoryVisibilityGate.shouldApply(visible: visible, isPlainGenericUpdate: true, hasScrollPosition: false, appliedOnce: !applied.isEmpty) else {
                return
            }
            prepared += 1
            let diff = view.filter { !previous.contains($0) }
            previous = view
            applied.append(diff)
        }
        emit([1])
        visible = false
        var view = [1]
        for id in 2 ... 11 {
            view.append(id)
            emit(view)
        }
        XCTAssertEqual(prepared, 1)
        visible = true
        emit(view)
        XCTAssertEqual(prepared, 2)
        XCTAssertEqual(applied, [[1], Array(2 ... 11)])
    }
}

final class WindowVisibilityTests: XCTestCase {
    func testNoWindowCountsAsVisible() {
        XCTAssertTrue(WindowVisibilityObserver.isVisible(window: nil, appIsHidden: false))
    }

    func testOrderedOutWindowIsNotVisible() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        XCTAssertFalse(WindowVisibilityObserver.isVisible(window: window, appIsHidden: false))
    }

    func testHiddenAppIsNotVisible() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        XCTAssertFalse(WindowVisibilityObserver.isVisible(window: window, appIsHidden: true))
    }

    func testObserverReportsChangesOnce() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var reported: [Bool] = []
        let center = NotificationCenter()
        let observer = WindowVisibilityObserver(notificationCenter: center, appIsHidden: { false }, onChange: { reported.append($0) })
        XCTAssertTrue(observer.isVisible)
        observer.window = window
        XCTAssertEqual(reported, [false])
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(reported, [false])
        observer.window = nil
        XCTAssertEqual(reported, [false, true])
    }
}
