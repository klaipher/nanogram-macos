#if canImport(AppKit)
import XCTest
import AppKit
@testable import RichTextEditorUI
import RichTextEditorCore

@available(macOS 12, *)
extension MediaBlockBox {
    var mediaRect: CGRect {
        let bleed = mediaBleeds ? contentMargin : 0
        return CGRect(x: frame.minX - bleed, y: mediaOrigin.y, width: frame.width + bleed * 2, height: mediaAreaHeight)
    }
}

@available(macOS 12, *)
final class CanvasImageSelectionTests: AppKitTestCase {
    private func canvas() -> DocumentCanvasView {
        let v = DocumentCanvasView()
        v.imageProvider = { [self] _ in image(of: CGSize(width: 80, height: 50), fill: .systemTeal) }
        v.setModelBlocks([
            .core(.paragraph(ParagraphBlock(id: BlockID("a"), runs: [TextRun(text: "Above")]))),
            .media(MediaBlock(id: BlockID("img"), kind: .image, mediaID: "x", naturalSize: Size2D(width: 80, height: 50),
                              caption: [TextRun(text: "Caption")])),
            .core(.paragraph(ParagraphBlock(id: BlockID("b"), runs: [TextRun(text: "Below")]))),
        ], width: 300)
        v.frame = CGRect(x: 0, y: 0, width: 300, height: 400); v.layoutSubtreeIfNeeded()
        return v
    }

    func test_selectionFlowsThroughCaption() {
        let v = canvas()
        let imgBox = v.boxes[1]
        // From inside "Above" through the caption into "Below" → rects in all three blocks.
        let rects = v.selectionRects(globalFrom: v.boxes[0].textStart + 2,
                                     globalTo: v.boxes[2].textStart + 2)
        func count(in box: CanvasBlock) -> Int { rects.filter { box.frame.intersects($0) }.count }
        XCTAssertGreaterThan(count(in: v.boxes[0]), 0)
        XCTAssertGreaterThan(count(in: imgBox), 0)        // caption rects
        XCTAssertGreaterThan(count(in: v.boxes[2]), 0)
    }

    func test_shiftEnterInImageCaption_exitsIntoNewParagraph() {
        let v = canvas()
        let img = v.boxes[1] as! MediaBlockBox
        v.setCaret(global: img.textStart + 2)   // inside the caption
        let before = v.boxes.count
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                 windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                 isARepeat: false, keyCode: 36)!
        v.keyDown(with: e)
        XCTAssertEqual(v.boxes.count, before + 1, "Shift+Enter adds a paragraph after the image")
        XCTAssertTrue(v.boxes[2] is BlockBox, "the new block after the image is a paragraph")
        XCTAssertEqual(v.head, v.boxes[2].textStart, "caret lands in the new paragraph")
    }

    func test_caretInCaption_isBelowImage() {
        let v = canvas()
        let imgBox = v.boxes[1] as! MediaBlockBox
        let caret = v.caretRect(forGlobal: imgBox.textStart)
        XCTAssertGreaterThan(caret.minY, imgBox.mediaOrigin.y)   // caption caret sits below the image
    }

    func test_caretAtImageGap_isVerticalBarAtImageLeadingEdge() {
        let v = canvas()
        let imgBox = v.boxes[1] as! MediaBlockBox
        // The gap before the image atom is a real caret position; we must report a drawable rect so
        // UITextSelectionDisplayInteraction renders the native caret there (not .zero, which is invisible).
        let caret = v.caretRect(forGlobal: imgBox.nodeStart)
        XCTAssertFalse(caret.isEmpty, "gap caret must be a drawable rect, not .zero")
        XCTAssertEqual(caret.minX, imgBox.frame.minX, accuracy: 0.5, "vertical caret sits at the image's leading edge")
        XCTAssertEqual(caret.minY, imgBox.mediaOrigin.y, accuracy: 0.5, "caret starts at the top of the media area")
        XCTAssertEqual(caret.height, imgBox.mediaAreaHeight, accuracy: 0.5, "caret spans the media area")
    }

    func test_typingInCaption_editsCaptionText() {
        let v = canvas()
        let imgBox = v.boxes[1] as! MediaBlockBox
        v.selectedGlobalRange = (imgBox.textStart + 7, imgBox.textStart + 7) // end of "Caption"
        v.commitText("!")
        guard case .media(let out) = v.boxes[1].currentModelBlock() else { return XCTFail() }
        XCTAssertEqual(out.caption.map(\.text).joined(), "Caption!")
    }
}
#endif
