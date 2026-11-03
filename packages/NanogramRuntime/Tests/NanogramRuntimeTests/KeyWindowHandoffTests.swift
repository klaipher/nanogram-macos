import AppKit
import XCTest
@testable import NanogramRuntime

@MainActor
private final class FakeWindow: KeyWindowHandoffCandidate {
    var isVisible: Bool
    var isMiniaturized: Bool
    var canBecomeKey: Bool

    init(isVisible: Bool = true, isMiniaturized: Bool = false, canBecomeKey: Bool = true) {
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
        self.canBecomeKey = canBecomeKey
    }
}

@MainActor
final class KeyWindowHandoffTests: XCTestCase {
    func testRestoresTheWindowThatWasKeyBeforeTheOverlay() {
        let overlay = FakeWindow()
        let previous = FakeWindow()
        let main = FakeWindow()
        XCTAssertTrue(KeyWindowHandoff.windowToRestore(previous: previous, fallback: main, overlay: overlay) === previous)
    }

    func testFallsBackToTheMainWindowWhenThePreviousOneIsGone() {
        let overlay = FakeWindow()
        let main = FakeWindow()
        XCTAssertTrue(KeyWindowHandoff.windowToRestore(previous: nil, fallback: main, overlay: overlay) === main)
        XCTAssertTrue(KeyWindowHandoff.windowToRestore(previous: FakeWindow(isVisible: false), fallback: main, overlay: overlay) === main)
        XCTAssertTrue(KeyWindowHandoff.windowToRestore(previous: FakeWindow(isMiniaturized: true), fallback: main, overlay: overlay) === main)
        XCTAssertTrue(KeyWindowHandoff.windowToRestore(previous: FakeWindow(canBecomeKey: false), fallback: main, overlay: overlay) === main)
    }

    func testNeverHandsKeyBackToTheOverlayItself() {
        let overlay = FakeWindow()
        let main = FakeWindow()
        XCTAssertTrue(KeyWindowHandoff.windowToRestore(previous: overlay, fallback: main, overlay: overlay) === main)
        XCTAssertNil(KeyWindowHandoff.windowToRestore(previous: overlay, fallback: overlay, overlay: overlay))
    }

    func testReturnsNothingWhenNoWindowCanTakeKey() {
        let overlay = FakeWindow()
        XCTAssertNil(KeyWindowHandoff.windowToRestore(previous: FakeWindow(isVisible: false), fallback: FakeWindow(isMiniaturized: true), overlay: overlay))
    }

    func testRealWindowsConform() {
        let overlay = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        let hidden = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertNil(KeyWindowHandoff.windowToRestore(previous: hidden, fallback: nil, overlay: overlay))
    }

    func testHandoffMakesTheRestoredWindowKeyBeforeTheOverlayLeaves() {
        let overlay = FakeWindow()
        let main = FakeWindow()
        var madeKey: [FakeWindow] = []
        KeyWindowHandoff.restore(previous: nil, fallback: main, overlay: overlay, makeKey: { madeKey.append($0) })
        XCTAssertEqual(madeKey.count, 1)
        XCTAssertTrue(madeKey.first === main)
    }

    func testHandoffDoesNothingWithoutACandidate() {
        let overlay = FakeWindow()
        var madeKey: [FakeWindow] = []
        KeyWindowHandoff.restore(previous: nil, fallback: nil, overlay: overlay, makeKey: { madeKey.append($0) })
        XCTAssertTrue(madeKey.isEmpty)
    }
}
