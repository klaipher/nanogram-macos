import Cocoa
import XCTest
@testable import ChatUI

final class ChatReactionsUpdatePlanTests: XCTestCase {
    // The row re-measures the same ChatReactionsLayout in place on resize; the view must still re-frame chips.
    func testSameLayoutObjectStillRelayouts() {
        XCTAssertEqual(ChatReactionsUpdatePlan.make(sameLayoutObject: true, viewCount: 3, reactionCount: 3), .relayoutOnly)
    }

    func testDifferentLayoutOrCountRebuilds() {
        XCTAssertEqual(ChatReactionsUpdatePlan.make(sameLayoutObject: false, viewCount: 3, reactionCount: 3), .rebuild)
        XCTAssertEqual(ChatReactionsUpdatePlan.make(sameLayoutObject: true, viewCount: 2, reactionCount: 3), .rebuild)
    }
}

final class ChatLayerSceneDiscoveryTests: XCTestCase {
    func testFindsNestedScenesBelowPlainViews() {
        let row = NSView(frame: .zero)
        let a = ChatLayerSceneView(frame: .zero)
        let wrapper = NSView(frame: .zero)
        let b = ChatLayerSceneView(frame: .zero)
        row.addSubview(a)
        row.addSubview(wrapper)
        wrapper.addSubview(b)
        let found = ChatLayerSceneView.scenes(in: row)
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.contains { $0 === a })
        XCTAssertTrue(found.contains { $0 === b })
    }

    func testIncludesRootWhenItIsAScene() {
        let a = ChatLayerSceneView(frame: .zero)
        XCTAssertEqual(ChatLayerSceneView.scenes(in: a).count, 1)
    }
}
