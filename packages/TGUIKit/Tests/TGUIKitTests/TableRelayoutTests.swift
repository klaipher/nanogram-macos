import AppKit
import XCTest
@testable import TGUIKit

private final class FixedItem: TableRowItem {
    private let rowHeight: CGFloat
    private(set) var makeSizeCalls = 0

    init(id: Int, height: CGFloat) {
        self.rowHeight = height
        super.init(.zero, stableId: id)
    }

    override var height: CGFloat {
        return rowHeight
    }

    override func makeSize(_ width: CGFloat = CGFloat.greatestFiniteMagnitude, oldWidth: CGFloat = 0) -> Bool {
        makeSizeCalls += 1
        if let id = stableId.base as? Int {
            NoteHeightSpy.measureOrder.append(id)
        }
        return super.makeSize(width, oldWidth: oldWidth)
    }
}

private enum NoteHeightSpy {
    static var calls: [IndexSet] = []
    static var measureOrder: [Int] = []
}

private final class SpyTableView: TGFlipableTableView {
    override func noteHeightOfRows(withIndexesChanged indexSet: IndexSet) {
        NoteHeightSpy.calls.append(indexSet)
        super.noteHeightOfRows(withIndexesChanged: indexSet)
    }
}

final class TableRelayoutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ModernizationFlag.deferredResizeRelayout.rawValue)
        super.tearDown()
    }

    private func makeTable(count: Int) -> (TableView, NSWindow, [FixedItem]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = TableView(frame: window.contentView!.bounds, isFlipped: false)
        window.contentView!.addSubview(table)
        var items: [FixedItem] = []
        for id in 0 ..< count {
            let item = FixedItem(id: id, height: 50)
            items.append(item)
            _ = table.addItem(item: item)
        }
        table.layoutSubtreeIfNeeded()
        return (table, window, items)
    }

    func testPlanCoversEveryIndexExactlyOnce() {
        let plan = TableRelayoutPlan(count: 100, visible: NSRange(location: 40, length: 10), chunkSize: 20)
        var all = Array(plan.immediate)
        all.append(contentsOf: plan.deferredChunks.flatMap { $0 })
        XCTAssertEqual(all.sorted(), Array(0 ..< 100))
        XCTAssertEqual(plan.immediate, 40 ..< 50)
        XCTAssertTrue(plan.deferredChunks.dropLast().allSatisfy { $0.count == 20 })
    }

    func testPlanOrdersDeferredRowsNearestFirst() {
        let plan = TableRelayoutPlan(count: 30, visible: NSRange(location: 10, length: 5), chunkSize: 4)
        XCTAssertEqual(plan.deferredChunks.first, [15, 9, 16, 8])
    }

    func testPlanHandlesEmptyAndOutOfRangeVisible() {
        XCTAssertTrue(TableRelayoutPlan(count: 0, visible: NSRange(location: 0, length: 0), chunkSize: 20).deferredChunks.isEmpty)
        let plan = TableRelayoutPlan(count: 5, visible: NSRange(location: 3, length: 50), chunkSize: 20)
        XCTAssertEqual(plan.immediate, 3 ..< 5)
        XCTAssertEqual(Set(plan.deferredChunks.flatMap { $0 }), [0, 1, 2])
    }

    func testFlagOffMeasuresEveryRowSynchronously() {
        let (table, window, items) = makeTable(count: 60)
        defer { window.close() }
        items.forEach { _ = $0.makeSize(320) }
        let before = items.map { $0.makeSizeCalls }
        table.layoutItems()
        XCTAssertTrue(zip(items, before).allSatisfy { $0.makeSizeCalls == $1 + 1 })
    }

    func testFlagOnMeasuresEveryRowEventually() {
        UserDefaults.standard.set(true, forKey: ModernizationFlag.deferredResizeRelayout.rawValue)
        let (table, window, items) = makeTable(count: 120)
        defer { window.close() }
        let before = items.map { $0.makeSizeCalls }
        table.layoutItems()
        let drained = expectation(description: "chunks drained")
        func poll() {
            if zip(items, before).allSatisfy({ $0.makeSizeCalls > $1 }) {
                drained.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
            }
        }
        poll()
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(table.count, 120)
    }

    func testFlagOnLeavesFarRowsUnmeasuredUntilTheMainQueueTurns() {
        UserDefaults.standard.set(true, forKey: ModernizationFlag.deferredResizeRelayout.rawValue)
        let (table, window, items) = makeTable(count: 200)
        defer { window.close() }
        let before = items.map { $0.makeSizeCalls }
        table.layoutItems()
        let measured = zip(items, before).filter { $0.makeSizeCalls > $1 }.count
        XCTAssertLessThan(measured, 200)
    }

    func testFlagOnNotesHeightOnceWithFullIndexSetAndMeasuresVisibleRowsFirst() {
        UserDefaults.standard.set(true, forKey: ModernizationFlag.deferredResizeRelayout.rawValue)
        let (table, window, _) = makeTable(count: 200)
        defer { window.close() }
        object_setClass(table.tableView, SpyTableView.self)
        NoteHeightSpy.calls = []
        NoteHeightSpy.measureOrder = []
        let visible = table.visibleRows(600)

        table.layoutItems()

        XCTAssertEqual(NoteHeightSpy.calls.first, IndexSet(integersIn: 0 ..< 200))
        XCTAssertEqual(NoteHeightSpy.calls.filter { $0.count == 200 }.count, 1)
        let leading = Set(NoteHeightSpy.measureOrder.prefix(visible.length))
        XCTAssertEqual(leading, Set(visible.location ..< visible.location + visible.length))
    }

    func testFlagOnKeepsScrollPositionChosenBetweenChunks() {
        UserDefaults.standard.set(true, forKey: ModernizationFlag.deferredResizeRelayout.rawValue)
        let (table, window, items) = makeTable(count: 200)
        defer { window.close() }
        let before = items.map { $0.makeSizeCalls }

        table.layoutItems()
        table.clipView.scroll(to: NSPoint(x: 0, y: 6000))
        let scrolledTo = table.documentOffset.y

        let drained = expectation(description: "chunks drained")
        func poll() {
            if zip(items, before).allSatisfy({ $0.makeSizeCalls > $1 }) {
                drained.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
            }
        }
        poll()
        wait(for: [drained], timeout: 5)

        XCTAssertEqual(table.documentOffset.y, scrolledTo, accuracy: 120)
    }
}
