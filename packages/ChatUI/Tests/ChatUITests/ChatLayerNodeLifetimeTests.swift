import Cocoa
import XCTest
@testable import ChatUI

final class ChatLayerNodeLifetimeTests: XCTestCase {
    func testChildDoesNotKeepDanglingParentAfterParentIsReleased() throws {
        let child = ChatLayerNode(id: "child")
        var parent: ChatLayerNode? = ChatLayerNode(id: "parent")
        try parent?.setChildren([child])
        XCTAssertTrue(child.parent === parent)
        parent = nil
        XCTAssertNil(child.parent)
    }

    func testNodesDoNotKeepDanglingSceneAfterSceneIsReleased() {
        let node = ChatLayerNode(id: "node")
        autoreleasepool {
            let scene = ChatLayerSceneView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            try? scene.root.setChildren([node])
            XCTAssertNotNil(node.scene)
        }
        XCTAssertNil(node.scene)
    }
}
