import AppKit
import XCTest
@testable import TGUIKit

/// Return, Escape, Space and the arrows go to the input method while it composes, never to window key
/// handlers (upstream #233 fixed only the media sender; Share, stories and other modals send on Return too).
final class InputMethodKeyRoutingTests: XCTestCase {
    private func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        return try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testComposingTextViewOwnsReturnEscapeSpaceAndArrows() throws {
        TGUIKitTestBootstrap.install()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        for (code, characters) in [(UInt16(36), "\r"), (76, "\u{3}"), (53, "\u{1b}"), (49, " "), (123, "\u{f702}"), (124, "\u{f703}"), (125, "\u{f701}"), (126, "\u{f700}")] {
            XCTAssertTrue(Window.keyBelongsToInputMethod(try key(code, characters), firstResponder: textView), "key \(code)")
        }
    }

    func testCommandShortcutsAndKeyUpStillReachWindowHandlers() throws {
        TGUIKitTestBootstrap.install()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(Window.keyBelongsToInputMethod(try key(36, "\r", modifiers: [.command]), firstResponder: textView))
        XCTAssertFalse(Window.keyBelongsToInputMethod(try key(36, "\r", type: .keyUp), firstResponder: textView))
    }

    func testWithoutMarkedTextWindowHandlersRun() throws {
        TGUIKitTestBootstrap.install()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        textView.string = "hello"
        XCTAssertFalse(Window.keyBelongsToInputMethod(try key(36, "\r"), firstResponder: textView))
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.unmarkText()
        XCTAssertFalse(Window.keyBelongsToInputMethod(try key(36, "\r"), firstResponder: textView))
        XCTAssertFalse(Window.keyBelongsToInputMethod(try key(36, "\r"), firstResponder: nil))
        XCTAssertFalse(Window.keyBelongsToInputMethod(try key(36, "\r"), firstResponder: NSView()))
    }
}
