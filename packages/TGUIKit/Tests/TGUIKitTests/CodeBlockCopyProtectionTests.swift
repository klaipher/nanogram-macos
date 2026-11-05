import Cocoa
import XCTest
@testable import TGUIKit

/// A code-block header copies its block only when the layout allows copying. `mayItems` is off for
/// copy-protected messages; the chat layer engine and TextView both go through copyableBlockQuoteText.
final class CodeBlockCopyProtectionTests: XCTestCase {
    override func setUp() { TGUIKitTestBootstrap.install() }

    private func codeLayout() -> TextViewLayout {
        let text = NSMutableAttributedString(string: "intro\nlet secret = 42")
        text.addAttribute(TextInputAttributes.quote, value: "code" as Any, range: NSRange(location: 6, length: 15))
        return TextViewLayout(text)
    }

    func testCopyableWhenItemsAreAllowed() {
        let layout = codeLayout()
        XCTAssertEqual(layout.copyableBlockQuoteText(startingWith: NSRange(location: 6, length: 1)), "let secret = 42")
    }

    func testProtectedLayoutRefusesTheCopy() {
        let layout = codeLayout()
        layout.mayItems = false
        XCTAssertNil(layout.copyableBlockQuoteText(startingWith: NSRange(location: 6, length: 1)))
        XCTAssertEqual(layout.blockQuoteText(startingWith: NSRange(location: 6, length: 1)), "let secret = 42", "the raw text accessor is unchanged")
    }
}
