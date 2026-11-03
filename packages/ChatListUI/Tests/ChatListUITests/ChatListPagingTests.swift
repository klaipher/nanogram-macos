import XCTest
@testable import ChatListUI

final class ChatListPagingTests: XCTestCase {
    private func request(above: CGFloat = 5000, below: CGFloat, viewport: CGFloat = 700, hasLater: Bool = false, hasEarlier: Bool = true, first: Int? = 1, last: Int? = 99, requested: Int? = nil) -> ChatListPageRequest<Int>? {
        return ChatListPaging.nextPageRequest(remainingAbove: above, remainingBelow: below, viewport: viewport, hasLater: hasLater, hasEarlier: hasEarlier, firstAnchor: first, lastAnchor: last, lastRequested: requested)
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

    func testLaterPageIsRequestedNearTheTopOfAMovedWindow() {
        XCTAssertEqual(request(above: 900, below: 5000, hasLater: true), ChatListPageRequest(direction: .later, anchor: 99))
        XCTAssertNil(request(above: 900, below: 5000, hasLater: false))
    }
}
