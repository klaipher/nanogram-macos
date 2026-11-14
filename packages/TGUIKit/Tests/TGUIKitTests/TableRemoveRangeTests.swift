import AppKit
import XCTest
@testable import TGUIKit

private final class RangeItem: TableRowItem {
    init(id: Int) {
        super.init(.zero, stableId: id)
    }

    override var height: CGFloat {
        return 50
    }
}

final class TableRemoveRangeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
    }

    private func makeTable(count: Int) -> (TableView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = TableView(frame: window.contentView!.bounds, isFlipped: false)
        window.contentView!.addSubview(table)
        for id in 0 ..< count {
            _ = table.addItem(item: RangeItem(id: id))
        }
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    func testRemoveRangeRemovesExactlyTheRange() {
        let (table, window) = makeTable(count: 10)
        defer { window.close() }
        table.remove(range: 2 ..< 5)
        XCTAssertEqual(table.count, 7)
        for id in 2 ..< 5 {
            XCTAssertNil(table.item(stableId: AnyHashable(id)))
        }
        let remaining = (0 ..< table.count).map { table.item(at: $0).stableId }
        XCTAssertEqual(remaining, [0, 1, 5, 6, 7, 8, 9].map { AnyHashable($0) })
    }

    func testRemoveRangeClampsToTheList() {
        let (table, window) = makeTable(count: 4)
        defer { window.close() }
        table.remove(range: 2 ..< 10)
        XCTAssertEqual(table.count, 2)
        table.remove(range: 5 ..< 8)
        XCTAssertEqual(table.count, 2)
    }
}
