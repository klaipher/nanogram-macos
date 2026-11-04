import XCTest
@testable import ChatUI

final class ChatEntertainmentButtonStateTests: XCTestCase {
    // Closing the panel with the same button: the sidebar view is still visible when the input updates.
    func testClosingByToggleDoesNotStayHighlighted() {
        XCTAssertFalse(ChatEntertainmentButtonState.isSelected(sidebarEnabled: true, sidebarShown: false, previousSidebarShown: true, sidebarVisibleNow: { true }))
    }

    func testOpeningByToggleHighlights() {
        XCTAssertTrue(ChatEntertainmentButtonState.isSelected(sidebarEnabled: true, sidebarShown: true, previousSidebarShown: false, sidebarVisibleNow: { false }))
    }

    func testUnrelatedUpdateFollowsLiveVisibility() {
        XCTAssertTrue(ChatEntertainmentButtonState.isSelected(sidebarEnabled: true, sidebarShown: true, previousSidebarShown: true, sidebarVisibleNow: { true }))
        XCTAssertFalse(ChatEntertainmentButtonState.isSelected(sidebarEnabled: true, sidebarShown: true, previousSidebarShown: true, sidebarVisibleNow: { false }))
    }
}
