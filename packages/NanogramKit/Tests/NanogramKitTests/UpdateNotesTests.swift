import XCTest
@testable import NanogramKit

final class UpdateNotesTests: XCTestCase {
    func test_plainTextIsReturnedUnchanged() {
        XCTAssertEqual(UpdateNotes.plainText(from: "Faster media loading"), "Faster media loading")
    }

    func test_tagsAreRemoved() {
        XCTAssertEqual(UpdateNotes.plainText(from: "<p>Fixed a <b>crash</b> in calls</p>"), "Fixed a crash in calls")
    }

    func test_listItemsBecomeBulletLines() {
        let text = UpdateNotes.plainText(from: "<ul><li>Faster chats</li><li>Better calls</li></ul>")
        XCTAssertEqual(text, "• Faster chats\n• Better calls")
    }

    func test_lineBreaksAndParagraphsBecomeNewlines() {
        XCTAssertEqual(UpdateNotes.plainText(from: "One<br>Two<br/>Three"), "One\nTwo\nThree")
        XCTAssertEqual(UpdateNotes.plainText(from: "<p>One</p><p>Two</p>"), "One\nTwo")
    }

    func test_entitiesAreDecoded() {
        XCTAssertEqual(UpdateNotes.plainText(from: "Tom &amp; Jerry &lt;3 &quot;hi&quot; &#39;x&#39; &#x41;&#66;"), "Tom & Jerry <3 \"hi\" 'x' AB")
    }

    func test_invalidNumericEntitiesStayLiteral() {
        XCTAssertEqual(UpdateNotes.plainText(from: "a &#99999999999; b &#xD800; c &bogus; d"), "a &#99999999999; b &#xD800; c &bogus; d")
    }

    func test_decodedEntitiesAreNotParsedAsTags() {
        XCTAssertEqual(UpdateNotes.plainText(from: "&lt;script&gt;alert(1)&lt;/script&gt;"), "<script>alert(1)</script>")
    }

    func test_scriptAndStyleContentIsDropped() {
        XCTAssertEqual(UpdateNotes.plainText(from: "Hello<script>alert(1)</script><style>p{color:red}</style>"), "Hello")
    }

    func test_unterminatedTagIsDropped() {
        XCTAssertEqual(UpdateNotes.plainText(from: "Fixed <b"), "Fixed")
    }

    func test_nilAndEmptyGiveEmptyText() {
        XCTAssertEqual(UpdateNotes.plainText(from: nil), "")
        XCTAssertEqual(UpdateNotes.plainText(from: ""), "")
    }

    func test_inlineBulletsStartANewLine() {
        XCTAssertEqual(UpdateNotes.plainText(from: "Changes • Faster chats • Better calls"), "Changes \n• Faster chats \n• Better calls")
    }

    func test_tabsBecomeTwoSpacesAndRunsOfSpacesShrink() {
        XCTAssertEqual(UpdateNotes.plainText(from: "a\tb      c"), "a  b  c")
    }
}
