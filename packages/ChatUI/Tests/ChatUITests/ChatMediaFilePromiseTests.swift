import XCTest
import AppKit
@testable import ChatUI

final class ChatMediaFilePromiseTests: XCTestCase {
    func testFileTypeFromKnownMimeType() {
        XCTAssertEqual(ChatMediaPromiseNaming.fileType(mimeType: "image/jpeg"), "public.jpeg")
        XCTAssertEqual(ChatMediaPromiseNaming.fileType(mimeType: "video/mp4"), "public.mpeg-4")
    }

    func testFileTypeFallsBackToData() {
        XCTAssertEqual(ChatMediaPromiseNaming.fileType(mimeType: nil), "public.data")
    }

    func testNameKeepsExistingExtension() {
        XCTAssertEqual(ChatMediaPromiseNaming.fileName(preferred: "clip.mov", mimeType: "video/mp4", fallbackStem: "FILE"), "clip.mov")
    }

    func testNameGetsExtensionFromMimeType() {
        XCTAssertEqual(ChatMediaPromiseNaming.fileName(preferred: "photo", mimeType: "image/jpeg", fallbackStem: "IMAGE"), "photo.jpeg")
    }

    func testMissingNameUsesFallbackStem() {
        XCTAssertEqual(ChatMediaPromiseNaming.fileName(preferred: nil, mimeType: "image/png", fallbackStem: "IMAGE 2026"), "IMAGE 2026.png")
    }

    func testSeparatorsAndLeadingDotAreSanitized() {
        XCTAssertEqual(ChatMediaPromiseNaming.sanitized("a/b:c"), "a_b_c")
        XCTAssertEqual(ChatMediaPromiseNaming.sanitized(".hidden"), "_hidden")
        XCTAssertEqual(ChatMediaPromiseNaming.sanitized("   "), "")
    }

    func testPromiseCompletionFiresOnce() {
        var calls = 0
        let completion = PromiseCompletion { _ in calls += 1 }
        completion.complete(nil)
        completion.complete(ChatMediaPromiseError.unavailable)
        XCTAssertEqual(calls, 1)
    }
}
