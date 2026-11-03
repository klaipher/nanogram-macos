import AppKit
import XCTest
@testable import TGUIKit

private final class DisplayCountingWindow: NSWindow {
    var displayIfNeededCalls = 0
    override func displayIfNeeded() {
        displayIfNeededCalls += 1
        super.displayIfNeeded()
    }
}

private final class BottomRowItem: TableRowItem {
    init(id: Int) {
        super.init(.zero, stableId: id)
    }

    override var height: CGFloat {
        return 50
    }
}

final class TableBottomInsertDisplayTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
    }

    private func insertAtBottom() -> (calls: Int, animated: [TableAnimationInterface.AnimateItem], newRowHasLayer: Bool, newRowNeedsDisplay: Bool) {
        let window = DisplayCountingWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let table = TableView(frame: window.contentView!.bounds, isFlipped: false)
        window.contentView!.addSubview(table)
        for id in 0 ..< 20 {
            _ = table.addItem(item: BottomRowItem(id: id))
        }
        table.layoutSubtreeIfNeeded()
        var animated: [TableAnimationInterface.AnimateItem] = []
        let interface = TableAnimationInterface(true, true, { items in
            animated = items
        })
        window.displayIfNeededCalls = 0
        let transition = TableUpdateTransition(deleted: [], inserted: [(0, BottomRowItem(id: 100))], updated: [], animated: true, state: .none(interface))
        table.merge(with: transition)
        let calls = window.displayIfNeededCalls
        let newRowHasLayer = table.viewNecessary(at: 0)?.layer != nil
        let newRowNeedsDisplay = table.viewNecessary(at: 0)?.needsDisplay ?? true
        return (calls, animated, newRowHasLayer, newRowNeedsDisplay)
    }

    func testBottomInsertionDoesNotDisplayTheWholeWindow() {
        let result = insertAtBottom()
        XCTAssertEqual(result.calls, 0)
    }

    func testBottomInsertionKeepsItsPositionAnimation() {
        let result = insertAtBottom()
        XCTAssertTrue(result.newRowHasLayer)
        XCTAssertFalse(result.newRowNeedsDisplay)
        let expected = (0 ..< 9).map { step -> (CGFloat, CGFloat) in
            return (CGFloat(step) * 50 - 50, CGFloat(step) * 50)
        }
        XCTAssertEqual(result.animated.map { $0.index }, Array(repeating: 0, count: 9))
        XCTAssertEqual(result.animated.map { $0.from.y }, expected.map { $0.0 })
        XCTAssertEqual(result.animated.map { $0.to.y }, expected.map { $0.1 })
    }
}
