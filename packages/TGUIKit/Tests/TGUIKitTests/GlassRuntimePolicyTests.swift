import XCTest
@testable import TGUIKit

final class GlassRuntimePolicyTests: XCTestCase {
    func testDebugParsingKnownUnknownAndAll() {
        XCTAssertEqual(GlassDebug.parse(nil), [])
        XCTAssertEqual(GlassDebug.parse(""), [])
        XCTAssertEqual(GlassDebug.parse("chatHeader,inputRow"), [.chatHeader, .inputRow])
        XCTAssertEqual(GlassDebug.parse(" tabBar , bogus ,toasts"), [.tabBar, .toasts])
        XCTAssertEqual(GlassDebug.parse("all"), Set(GlassGroup.allCases))
    }

    func testUngroupedGlassIsNeverDisabled() {
        XCTAssertFalse(GlassDebug.isDisabled(nil))
    }

    func testDisabledGroupsAreEmptyWithoutLaunchArgument() {
        XCTAssertTrue(GlassDebug.disabledGroups.isEmpty)
    }
}
