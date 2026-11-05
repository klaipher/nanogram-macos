import XCTest
@testable import GalleryUI

/// Upstream #231 moved the "this file may be harmful" confirmation into QuickLookPreview.show, so every
/// route (chat, shared media, storage usage, polls) asks first. These check the list itself.
final class QuickLookPreviewWarningTests: XCTestCase {
    func testUpstreamExtensionsStillWarn() {
        for name in ["run.sh", "Setup.command", "page.HTML", "image.svg", "Installer.pkg", "disk.dmg", "notes.md", "macro.docm"] {
            XCTAssertTrue(needsPreviewWarning(fileName: name, mimeType: "application/octet-stream"), name)
        }
    }

    func testWebContentQuickLookRendersWarns() {
        for name in ["saved.webarchive", "page.xht", "drawing.svgz", "page.shtml"] {
            XCTAssertTrue(needsPreviewWarning(fileName: name, mimeType: "application/octet-stream"), name)
        }
    }

    func testFilesOpenedOutsideQuickLookThatCanRunSomethingWarn() {
        for name in ["shell.terminal", "build.tool", "Flow.workflow", "Do.action", "script.scpt", "bundle.scptd", "source.applescript", "app.jar", "Open.fileloc", "link.inetloc", "profile.mobileconfig", "pane.prefpane"] {
            XCTAssertTrue(needsPreviewWarning(fileName: name, mimeType: "application/octet-stream"), name)
        }
    }

    func testOrdinaryDocumentsDoNotWarn() {
        for name in ["report.pdf", "photo.jpg", "table.xlsx", "letter.docx", "notes.txt", "archive.zip", nil] as [String?] {
            XCTAssertFalse(needsPreviewWarning(fileName: name, mimeType: "application/pdf"), name ?? "nil")
        }
    }

    func testAnExtensionInsideTheNameIsNotEnough() {
        XCTAssertFalse(needsPreviewWarning(fileName: "html-guide.pdf", mimeType: "application/pdf"))
        XCTAssertFalse(needsPreviewWarning(fileName: "my.sh.txt", mimeType: "text/plain"))
    }
}
