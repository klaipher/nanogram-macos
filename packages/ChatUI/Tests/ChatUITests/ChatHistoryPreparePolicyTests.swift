import XCTest
@testable import ChatUI

final class ChatHistoryPreparePolicyTests: XCTestCase {
    func testFirstInitialUpdateBuildsOnlyTheViewportAndStaysOffMain() {
        let placement = ChatHistoryPreparePolicy.placement(themeChanged: false, isInitialUpdate: true, followsLoadingUpdate: true)
        XCTAssertEqual(placement, ChatHistoryPreparePlacement(runsOnMainQueue: false, buildsViewportFirst: true))
    }

    func testInitialUpdateAfterRealDataIsOrdinary() {
        let placement = ChatHistoryPreparePolicy.placement(themeChanged: false, isInitialUpdate: true, followsLoadingUpdate: false)
        XCTAssertEqual(placement, ChatHistoryPreparePlacement(runsOnMainQueue: false, buildsViewportFirst: false))
    }

    func testThemeChangeStillRunsOnMainAndKeepsTheViewportPath() {
        for initial in [true, false] {
            for loading in [true, false] {
                let placement = ChatHistoryPreparePolicy.placement(themeChanged: true, isInitialUpdate: initial, followsLoadingUpdate: loading)
                XCTAssertEqual(placement, ChatHistoryPreparePlacement(runsOnMainQueue: true, buildsViewportFirst: true))
            }
        }
    }

    func testGenericUpdatesNeverUseTheViewportPathOrMain() {
        let placement = ChatHistoryPreparePolicy.placement(themeChanged: false, isInitialUpdate: false, followsLoadingUpdate: true)
        XCTAssertEqual(placement, ChatHistoryPreparePlacement(runsOnMainQueue: false, buildsViewportFirst: false))
    }
}
