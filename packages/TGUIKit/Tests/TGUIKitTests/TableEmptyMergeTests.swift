import AppKit
import XCTest
@testable import TGUIKit

private final class MergeResultItem: TableRowItem {
    init(id: Int) {
        super.init(.zero, stableId: id)
    }

    override var height: CGFloat {
        return 40
    }
}

extension TableMergeResultTests {
    private func withTable(_ body: (TableView) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let table = TableView(frame: window.contentView!.bounds, isFlipped: false)
        window.contentView!.addSubview(table)
        for id in 0 ..< 20 {
            _ = table.addItem(item: MergeResultItem(id: id))
        }
        table.layoutSubtreeIfNeeded()
        body(table)
    }

    private func emptyGeneric() -> TableUpdateTransition {
        return TableUpdateTransition(deleted: [], inserted: [], updated: [], animated: true, state: .none(TableAnimationInterface(true, true, { _ in })))
    }

    func testEmptyGenericTransitionsWithFreshAnimationInterfacesShortCircuit() {
        withTable { table in
            table.merge(with: emptyGeneric())
            XCTAssertFalse(table.merge(with: emptyGeneric()))
            XCTAssertFalse(table.merge(with: emptyGeneric()))
        }
    }

    func testNonEmptyGenericTransitionStillMerges() {
        withTable { table in
            table.merge(with: emptyGeneric())
            let insert = TableUpdateTransition(deleted: [], inserted: [(0, MergeResultItem(id: 100))], updated: [], animated: true, state: .none(TableAnimationInterface(true, true, { _ in })))
            XCTAssertTrue(table.merge(with: insert))
            XCTAssertNotNil(table.item(stableId: AnyHashable(100)))
        }
    }

    func testEmptyTransitionWithDifferentScrollStateStillMerges() {
        withTable { table in
            table.merge(with: emptyGeneric())
            XCTAssertTrue(table.merge(with: TableUpdateTransition(deleted: [], inserted: [], updated: [], state: .saveVisible(.upper, false))))
        }
    }
}
