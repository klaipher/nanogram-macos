import XCTest
@testable import ChatListUI

private enum PageKey: Equatable {
    case initial(folder: Int)
    case index(folder: Int, anchor: Int)
}

private struct PagingModel {
    let total: Int
    let viewport: CGFloat
    let rowHeight: CGFloat = 70
    let folder: Int = 0
    var lo: Int = 0
    var hi: Int
    var top: CGFloat = 0
    var key: PageKey
    var pager = ChatListPager<Int, PageKey>()
    var requests: [ChatListPageRequest<Int>] = []

    init(total: Int = 3000, viewport: CGFloat, initial: Int = 50) {
        self.total = total
        self.viewport = viewport
        self.hi = min(total, initial)
        self.key = .initial(folder: 0)
        pager.didApply(window: window, key: key)
    }

    var window: ChatListPageWindow<Int> {
        return ChatListPageWindow(hasLater: lo > 0, hasEarlier: hi < total, firstAnchor: hi - 1, lastAnchor: lo)
    }

    var geometry: ChatListPageGeometry {
        let offset = top - CGFloat(lo) * rowHeight
        let below = CGFloat(hi) * rowHeight - top - viewport
        return ChatListPageGeometry(remainingAbove: offset, remainingBelow: below, viewport: viewport, rowHeight: rowHeight)
    }

    var visibleRow: Int {
        return Int(top / rowHeight)
    }

    @discardableResult
    mutating func check() -> Bool {
        guard let request = pager.nextRequest(currentKey: key, geometry: geometry, isAnimatingScroll: false) else {
            return false
        }
        requests.append(request)
        key = .index(folder: folder, anchor: request.anchor)
        lo = max(0, request.anchor - Int(ChatListPaging.halfWindowRows))
        hi = min(total, request.anchor + Int(ChatListPaging.halfWindowRows) + 1)
        pager.didApply(window: window, key: key)
        return true
    }

    mutating func scroll(by delta: CGFloat) {
        pager.didScroll(towards: delta > 0 ? .earlier : .later)
        top = max(CGFloat(lo) * rowHeight, min(top + delta, CGFloat(hi) * rowHeight - viewport))
        check()
    }

    mutating func stationaryRequests(checks: Int = 20) -> Int {
        var count = 0
        for _ in 0 ..< checks where check() {
            count += 1
        }
        return count
    }
}

final class ChatListPagingTests: XCTestCase {
    private func request(above: CGFloat = 5000, below: CGFloat, viewport: CGFloat = 700, direction: ChatListPageDirection = .earlier, hasLater: Bool = false, hasEarlier: Bool = true, first: Int? = 1, last: Int? = 99, requested: Int? = nil) -> ChatListPageRequest<Int>? {
        let window = ChatListPageWindow(hasLater: hasLater, hasEarlier: hasEarlier, firstAnchor: first, lastAnchor: last)
        let geometry = ChatListPageGeometry(remainingAbove: above, remainingBelow: below, viewport: viewport, rowHeight: 70)
        return ChatListPaging.nextPageRequest(window: window, geometry: geometry, direction: direction, lastRequested: requested)
    }

    func testEarlierPageIsRequestedWellBeforeTheEnd() {
        XCTAssertEqual(request(below: 1050, viewport: 700), ChatListPageRequest(direction: .earlier, anchor: 1))
        XCTAssertEqual(request(below: 1500, viewport: 1000), ChatListPageRequest(direction: .earlier, anchor: 1))
        XCTAssertEqual(request(below: 1399, viewport: 300), ChatListPageRequest(direction: .earlier, anchor: 1))
    }

    func testNothingIsRequestedWhileEnoughRowsRemainBelow() {
        XCTAssertNil(request(below: 1450, viewport: 700))
        XCTAssertNil(request(below: 2100, viewport: 1000))
    }

    func testConsecutiveDifferentAnchorsAreNotThrottled() {
        var lastRequested: Int?
        var fired: [Int] = []
        for anchor in [10, 20] {
            if let next = request(below: 200, first: anchor, requested: lastRequested) {
                fired.append(next.anchor)
                lastRequested = next.anchor
            }
        }
        XCTAssertEqual(fired, [10, 20])
    }

    func testTheSameAnchorIsRequestedOnce() {
        var lastRequested: Int?
        var fired = 0
        for _ in 0 ..< 3 {
            if let next = request(below: 200, first: 10, requested: lastRequested) {
                fired += 1
                lastRequested = next.anchor
            }
        }
        XCTAssertEqual(fired, 1)
    }

    func testNothingIsRequestedAtTheEndOfTheList() {
        XCTAssertNil(request(below: 0, hasEarlier: false))
    }

    func testLaterPageIsRequestedNearTheTopOfAMovedWindowWhenScrollingUp() {
        XCTAssertEqual(request(above: 900, below: 5000, direction: .later, hasLater: true), ChatListPageRequest(direction: .later, anchor: 99))
        XCTAssertNil(request(above: 900, below: 5000, direction: .later, hasLater: false))
    }

    func testOnlyTheDirectionTheUserScrolledIsLoaded() {
        XCTAssertNil(request(above: 900, below: 900, direction: .earlier, hasLater: true, hasEarlier: false))
        XCTAssertNil(request(above: 900, below: 900, direction: .later, hasLater: false, hasEarlier: true))
        XCTAssertEqual(request(above: 900, below: 900, direction: .earlier, hasLater: true, hasEarlier: true), ChatListPageRequest(direction: .earlier, anchor: 1))
    }

    func testPreloadDistanceLeavesAFullPageAfterRecentring() {
        for viewport: CGFloat in [700, 900, 1400, 1500, 1800, 2400, 4000] {
            let distance = ChatListPaging.preloadDistance(viewport: viewport, rowHeight: 70)
            XCTAssertLessThanOrEqual(distance + viewport, ChatListPaging.halfWindowRows * 70, "viewport \(viewport)")
            XCTAssertGreaterThanOrEqual(distance, min(max(viewport * 2, ChatListPaging.minimumPreload), ChatListPaging.halfWindowRows * 70 - viewport), "viewport \(viewport)")
        }
        XCTAssertEqual(ChatListPaging.preloadDistance(viewport: 900, rowHeight: 70), 1800)
    }

    func testTallViewportsStayQuietAfterAPageMovesTheWindow() {
        for viewport: CGFloat in [900, 1400, 1500, 1800, 2400] {
            var model = PagingModel(viewport: viewport)
            while model.requests.count < 2 {
                model.scroll(by: 10)
            }
            XCTAssertTrue(model.window.hasLater, "viewport \(viewport)")
            XCTAssertEqual(model.requests.count, 2, "viewport \(viewport)")
            XCTAssertEqual(model.stationaryRequests(), 0, "viewport \(viewport)")
        }
    }

    func testTallViewportsDoNotPingPongWhileScrolling() {
        for viewport: CGFloat in [900, 1400, 1500, 1800, 2400] {
            var model = PagingModel(viewport: viewport)
            var paused = 0
            for step in 0 ..< 7000 {
                model.scroll(by: 10)
                if step % 40 == 39 {
                    paused += model.stationaryRequests()
                }
            }
            let rows = model.visibleRow
            XCTAssertGreaterThan(rows, 900, "viewport \(viewport)")
            XCTAssertEqual(paused, 0, "viewport \(viewport)")
            XCTAssertTrue(model.requests.allSatisfy { $0.direction == .earlier }, "viewport \(viewport)")
            XCTAssertLessThanOrEqual(model.requests.count, rows / 100 + 2, "viewport \(viewport)")
        }
    }

    func testScrollingBackUpLoadsLaterPagesWithoutPingPong() {
        for viewport: CGFloat in [1500, 1800, 2400] {
            var model = PagingModel(viewport: viewport)
            for _ in 0 ..< 5000 {
                model.scroll(by: 10)
            }
            let downRequests = model.requests.count
            for _ in 0 ..< 5000 {
                model.scroll(by: -10)
            }
            let upRequests = Array(model.requests.dropFirst(downRequests))
            XCTAssertFalse(upRequests.isEmpty, "viewport \(viewport)")
            XCTAssertTrue(upRequests.allSatisfy { $0.direction == .later }, "viewport \(viewport)")
            XCTAssertLessThanOrEqual(upRequests.count, 5000 * 10 / 7000 + 2, "viewport \(viewport)")
            XCTAssertEqual(model.stationaryRequests(), 0, "viewport \(viewport)")
        }
    }

    func testNothingIsRequestedWhileTheListScrollsProgrammatically() {
        var pager = ChatListPager<Int, PageKey>()
        pager.didApply(window: ChatListPageWindow(hasLater: true, hasEarlier: true, firstAnchor: 100, lastAnchor: 300), key: .initial(folder: 0))
        let nearEnd = ChatListPageGeometry(remainingAbove: 100, remainingBelow: 100, viewport: 700, rowHeight: 70)
        XCTAssertNil(pager.nextRequest(currentKey: .initial(folder: 0), geometry: nearEnd, isAnimatingScroll: true))
        XCTAssertEqual(pager.nextRequest(currentKey: .initial(folder: 0), geometry: nearEnd, isAnimatingScroll: false), ChatListPageRequest(direction: .earlier, anchor: 100))
    }

    func testSwitchingFoldersDeepInTheListWaitsForTheNewFolder() {
        var pager = ChatListPager<Int, PageKey>()
        pager.didScroll(towards: .later)
        pager.didApply(window: ChatListPageWindow(hasLater: true, hasEarlier: true, firstAnchor: 900, lastAnchor: 1100), key: .index(folder: 1, anchor: 1000))
        pager.restart()
        let oldTableNearTop = ChatListPageGeometry(remainingAbove: 200, remainingBelow: 9000, viewport: 700, rowHeight: 70)
        XCTAssertNil(pager.nextRequest(currentKey: .initial(folder: 2), geometry: oldTableNearTop, isAnimatingScroll: false))
        pager.didApply(window: ChatListPageWindow(hasLater: false, hasEarlier: true, firstAnchor: 50, lastAnchor: 0), key: .initial(folder: 2))
        let newFolderTop = ChatListPageGeometry(remainingAbove: 0, remainingBelow: 2800, viewport: 700, rowHeight: 70)
        XCTAssertNil(pager.nextRequest(currentKey: .initial(folder: 2), geometry: newFolderTop, isAnimatingScroll: false))
        let newFolderNearEnd = ChatListPageGeometry(remainingAbove: 1500, remainingBelow: 1300, viewport: 700, rowHeight: 70)
        XCTAssertEqual(pager.nextRequest(currentKey: .initial(folder: 2), geometry: newFolderNearEnd, isAnimatingScroll: false), ChatListPageRequest(direction: .earlier, anchor: 50))
    }

    func testScrollToTopIsNotOverriddenByTheMovedWindow() {
        var pager = ChatListPager<Int, PageKey>()
        pager.didScroll(towards: .later)
        pager.didApply(window: ChatListPageWindow(hasLater: true, hasEarlier: true, firstAnchor: 900, lastAnchor: 1100), key: .index(folder: 0, anchor: 1000))
        pager.restart()
        let atTopOfOldWindow = ChatListPageGeometry(remainingAbove: 0, remainingBelow: 9000, viewport: 700, rowHeight: 70)
        XCTAssertNil(pager.nextRequest(currentKey: .initial(folder: 0), geometry: atTopOfOldWindow, isAnimatingScroll: false))
    }

    func testNoSecondRequestUntilTheFirstAnswerIsApplied() {
        var pager = ChatListPager<Int, PageKey>()
        let windowA = ChatListPageWindow(hasLater: true, hasEarlier: true, firstAnchor: 100, lastAnchor: 300)
        pager.didApply(window: windowA, key: .index(folder: 0, anchor: 200))
        let nearBottomOfA = ChatListPageGeometry(remainingAbove: 9000, remainingBelow: 600, viewport: 700, rowHeight: 70)
        let first = pager.nextRequest(currentKey: .index(folder: 0, anchor: 200), geometry: nearBottomOfA, isAnimatingScroll: false)
        XCTAssertEqual(first, ChatListPageRequest(direction: .earlier, anchor: 100))
        let pendingKey = PageKey.index(folder: 0, anchor: 100)
        let stillTableA = ChatListPageGeometry(remainingAbove: 9000, remainingBelow: 100, viewport: 700, rowHeight: 70)
        XCTAssertNil(pager.nextRequest(currentKey: pendingKey, geometry: stillTableA, isAnimatingScroll: false))
        pager.didScroll(towards: .later)
        let flickedBackNearTopOfA = ChatListPageGeometry(remainingAbove: 300, remainingBelow: 9000, viewport: 700, rowHeight: 70)
        XCTAssertNil(pager.nextRequest(currentKey: pendingKey, geometry: flickedBackNearTopOfA, isAnimatingScroll: false))
        pager.didScroll(towards: .earlier)
        let windowB = ChatListPageWindow(hasLater: true, hasEarlier: true, firstAnchor: 0, lastAnchor: 200)
        pager.didApply(window: windowB, key: pendingKey)
        let tableBNearItsEnd = ChatListPageGeometry(remainingAbove: 9000, remainingBelow: 600, viewport: 700, rowHeight: 70)
        XCTAssertEqual(pager.nextRequest(currentKey: pendingKey, geometry: tableBNearItsEnd, isAnimatingScroll: false), ChatListPageRequest(direction: .earlier, anchor: 0))
    }
}
