import XCTest
@testable import InAppSettings

final class DownloadFolderAccessTests: XCTestCase {
    private let roots = ["/Users/me/Downloads"]

    private func settings(folder: String, bookmark: Data? = nil) -> AutomaticMediaDownloadSettings {
        return AutomaticMediaDownloadSettings.defaultSettings.withUpdatedDownloadFolder(folder, bookmark: bookmark)
    }

    func testDownloadsAndItsSubfoldersAreInside() {
        XCTAssertTrue(DownloadFolderAccess.isInsideDownloads("/Users/me/Downloads", roots: roots))
        XCTAssertTrue(DownloadFolderAccess.isInsideDownloads("/Users/me/Downloads/", roots: roots))
        XCTAssertTrue(DownloadFolderAccess.isInsideDownloads("/Users/me/Downloads/Telegram", roots: roots))
    }

    func testOtherFoldersAndLookalikesAreOutside() {
        XCTAssertFalse(DownloadFolderAccess.isInsideDownloads("/Users/me/Documents/Telegram", roots: roots))
        XCTAssertFalse(DownloadFolderAccess.isInsideDownloads("/Users/me/Downloads2", roots: roots))
        XCTAssertFalse(DownloadFolderAccess.isInsideDownloads("/Users/me/Downloads/../Documents", roots: roots))
    }

    func testSandboxedFolderOutsideDownloadsWithoutBookmarkNeedsReselection() {
        let outside = settings(folder: "/Users/me/Documents/Telegram")
        XCTAssertTrue(DownloadFolderAccess.needsReselection(outside, sandboxed: true, roots: roots))
        XCTAssertFalse(DownloadFolderAccess.needsReselection(outside, sandboxed: false, roots: roots))
    }

    func testBookmarkedOrDownloadsFolderNeedsNothing() {
        XCTAssertFalse(DownloadFolderAccess.needsReselection(settings(folder: "/Users/me/Documents/Telegram", bookmark: Data([1, 2, 3])), sandboxed: true, roots: roots))
        XCTAssertFalse(DownloadFolderAccess.needsReselection(settings(folder: "/Users/me/Downloads/Telegram"), sandboxed: true, roots: roots))
    }

    func testBookmarkSurvivesStorageAndOldRecordsHaveNone() throws {
        let withBookmark = settings(folder: "/x", bookmark: Data([9, 8, 7]))
        let decoded = try JSONDecoder().decode(AutomaticMediaDownloadSettings.self, from: JSONEncoder().encode(withBookmark))
        XCTAssertEqual(decoded.downloadFolderBookmark, Data([9, 8, 7]))
        XCTAssertEqual(decoded, withBookmark)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(withBookmark)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "db"))
        let old = try JSONDecoder().decode(AutomaticMediaDownloadSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.downloadFolderBookmark)
    }

    func testOtherUpdatesKeepTheBookmarkAndAFolderChangeReplacesIt() {
        let withBookmark = settings(folder: "/x", bookmark: Data([1]))
        XCTAssertEqual(withBookmark.withUpdatedAutomaticDownload(false).downloadFolderBookmark, Data([1]))
        XCTAssertEqual(withBookmark.withUpdatedRespectLowDataMode(false).downloadFolderBookmark, Data([1]))
        XCTAssertNil(withBookmark.withUpdatedDownloadFolder("/y").downloadFolderBookmark)
    }

    func testAccessWithoutBookmarkJustRunsTheBody() {
        var ran = false
        let value = DownloadFolderAccess.withAccess(settings(folder: "/x")) { () -> Int in
            ran = true
            return 5
        }
        XCTAssertTrue(ran)
        XCTAssertEqual(value, 5)
    }

    func testAnUnreadableBookmarkStillRunsTheBody() {
        let value = DownloadFolderAccess.withAccess(settings(folder: "/x", bookmark: Data([0, 1]))) { 7 }
        XCTAssertEqual(value, 7)
    }
}
