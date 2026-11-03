import AppKit
import XCTest
import TGUIKit
@testable import ChatListUI

final class ChatListScrollDisplayTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UITestBootstrap.install()
    }

    func testChatListClipViewSkipsTheNeedsDisplayWalkWhileScrolling() {
        let view = PeerListContainerView(frame: NSMakeRect(0, 0, 380, 700))
        XCTAssertTrue(view.tableView.clipView.skipsDisplayOnScroll)
    }
}
