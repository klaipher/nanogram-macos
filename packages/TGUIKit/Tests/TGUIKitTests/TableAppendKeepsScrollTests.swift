import AppKit
import XCTest
@testable import TGUIKit

private final class AppendRowItem: TableRowItem {
    init(id: Int) {
        super.init(.zero, stableId: id)
    }

    override var height: CGFloat {
        return 70
    }
}

final class TableAppendKeepsScrollTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
    }

    private func makeTable(window: NSWindow, rows: Int) throws -> TableView {
        let content = try XCTUnwrap(window.contentView)
        let table = TableView(frame: content.bounds)
        content.addSubview(table)
        for id in 0 ..< rows {
            _ = table.addItem(item: AppendRowItem(id: id))
        }
        table.layoutSubtreeIfNeeded()
        return table
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func appendTransition(from start: Int, count: Int) -> TableUpdateTransition {
        let inserted = (start ..< start + count).map { ($0, AppendRowItem(id: $0) as TableRowItem) }
        return TableUpdateTransition(deleted: [], inserted: inserted, updated: [], animated: false, state: .saveVisible(.lower, false))
    }

    func testAppendingRowsBelowLeavesTheScrollPositionAlone() throws {
        let window = makeWindow()
        defer { window.close() }
        let table = try makeTable(window: window, rows: 60)
        table.clipView.scroll(to: NSMakePoint(0, 1500))
        let origin = table.clipView.bounds.origin
        var completions = 0
        let previous = table.clipView.scrollDidComplete
        table.clipView.scrollDidComplete = { success in
            completions += 1
            previous?(success)
        }
        table.merge(with: appendTransition(from: 60, count: 40))
        XCTAssertEqual(table.clipView.bounds.origin, origin)
        XCTAssertEqual(completions, 0)
    }

    func testRemovingRowsAboveStillKeepsTheVisibleRowsInPlace() throws {
        let window = makeWindow()
        defer { window.close() }
        let table = try makeTable(window: window, rows: 60)
        table.clipView.scroll(to: NSMakePoint(0, 2100))
        let firstVisible = table.visibleRows().location
        let offsetInRow = table.clipView.bounds.minY - table.rectOf(index: firstVisible).minY
        let anchorId = table.item(at: firstVisible).stableId
        let transition = TableUpdateTransition(deleted: Array((0 ..< 10).reversed()), inserted: [], updated: [], animated: false, state: .saveVisible(.lower, false))
        table.merge(with: transition)
        let anchor = try XCTUnwrap(table.item(stableId: anchorId))
        XCTAssertEqual(table.clipView.bounds.minY - table.rectOf(item: anchor).minY, offsetInRow, accuracy: 0.5)
    }

    func testRemovingTheLastRowsAtTheBottomKeepsThePositionInsideTheContent() throws {
        let window = makeWindow()
        defer { window.close() }
        let table = try makeTable(window: window, rows: 60)
        let maxOffset = table.documentSize.height - table.clipView.bounds.height
        table.clipView.scroll(to: NSMakePoint(0, maxOffset))
        let transition = TableUpdateTransition(deleted: Array((55 ..< 60).reversed()), inserted: [], updated: [], animated: false, state: .saveVisible(.lower, false))
        table.merge(with: transition)
        let newMaxOffset = table.documentSize.height - table.clipView.bounds.height
        XCTAssertLessThanOrEqual(table.clipView.bounds.minY, newMaxOffset + 0.5)
    }
}
