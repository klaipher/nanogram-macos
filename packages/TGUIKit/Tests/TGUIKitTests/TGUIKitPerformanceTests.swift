import AppKit
import XCTest
import TGUIKit
import protocol TGUIKit.Identifiable

/// Hot paths of the chat list and the chat that need no app: the diff of a chat list update and the layout of a long
/// message. The same shapes are measured on iOS (ChatListUITests/ChatListDiffPerformanceTests,
/// DisplayTests/TextLayoutPerformanceTests). Each measures wall clock, CPU and peak memory.
///
/// Skipped unless TG_PERF=1, so `tg test` stays fast and free of timing noise. Run with `tools/dev/tg perf run`
/// (docs/profiling.md, "Tests that measure"); shared perfgate (nanogram-deps tools/perfgate.py) compares the numbers with the repository baselines.
final class TGUIKitPerformanceTests: XCTestCase {
    private struct Row: Comparable, Identifiable {
        let stableId: Int
        let sortKey: Int
        let revision: Int

        static func < (lhs: Row, rhs: Row) -> Bool {
            return lhs.sortKey > rhs.sortKey
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TG_PERF"] == "1", "performance tests run with TG_PERF=1 (tg perf run)")
        TGUIKitTestBootstrap.install()
    }

    private func measureOptions(iterations: Int) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        return options
    }

    /// 10000 rows against the same rows after 500 changed, 60 moved to the top and 30 were removed: the shape of an
    /// update that arrives while the list is open.
    func testDiffChatListAfterAnUpdate() {
        let count = 10000
        let before = (0 ..< count).map { Row(stableId: $0, sortKey: count - $0, revision: 0) }
        var updated = before
        for index in stride(from: 0, to: count, by: 20) {
            updated[index] = Row(stableId: updated[index].stableId, sortKey: updated[index].sortKey, revision: 1)
        }
        for index in 1 ..< 60 {
            updated[count - index] = Row(stableId: updated[count - index].stableId, sortKey: count + index, revision: 1)
        }
        for index in stride(from: 100, to: 400, by: 10) {
            updated.removeAll(where: { $0.stableId == index })
        }
        let after = updated.sorted()

        var changes = 0
        self.measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: self.measureOptions(iterations: 10)) {
            let (removed, inserted, changed) = mergeListsStableWithUpdates(leftList: before, rightList: after)
            changes = removed.count + inserted.count + changed.count
        }
        XCTAssertGreaterThan(changes, 0)
    }

    /// About 48,000 characters, a bold run every 300 characters and a link, at the width of a chat bubble.
    func testLayoutLongMessage() {
        let paragraph = "Some words that fill a line of an ordinary message, with emoji \u{1F600} and a link https://example.org/path in it. "
        let text = NSMutableAttributedString(string: String(repeating: paragraph, count: 400), attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.black
        ])
        var location = 0
        while location + 40 < text.length {
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: location, length: 12))
            location += 300
        }

        var lineCount = 0
        self.measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: self.measureOptions(iterations: 10)) {
            let layout = TextViewLayout(text)
            layout.measure(width: 320)
            lineCount = layout.lines.count
        }
        XCTAssertGreaterThan(lineCount, 400)
    }
}
