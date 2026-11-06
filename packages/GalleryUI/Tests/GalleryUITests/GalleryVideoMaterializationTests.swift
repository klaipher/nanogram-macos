import XCTest
@testable import GalleryUI

final class GalleryVideoMaterializationTests: XCTestCase {
    func testItemThatIsNotShownKeepsItsPlayerUncreatedForTheInitialOrientation() {
        XCTAssertFalse(GalleryVideoMaterialization.shouldMaterialize(orientation: Optional<Int>.none, isPlayerCreated: false))
    }

    func testAnItemWithACreatedPlayerKeepsReceivingOrientationUpdates() {
        XCTAssertTrue(GalleryVideoMaterialization.shouldMaterialize(orientation: Optional<Int>.none, isPlayerCreated: true))
        XCTAssertTrue(GalleryVideoMaterialization.shouldMaterialize(orientation: 1, isPlayerCreated: true))
    }

    func testRotatingAnItemCreatesItsPlayer() {
        XCTAssertTrue(GalleryVideoMaterialization.shouldMaterialize(orientation: 1, isPlayerCreated: false))
    }

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/GalleryUI/\(name)"), encoding: .utf8)
    }

    func testVideoItemInitDoesNotTouchTheViewBeforeTheGuard() throws {
        let text = try source("MGalleryVideoItem.swift")
        let guardRange = try XCTUnwrap(text.range(of: "GalleryVideoMaterialization.shouldMaterialize"))
        let viewRange = try XCTUnwrap(text.range(of: "self.controller.genericView"))
        XCTAssertTrue(guardRange.lowerBound < viewRange.lowerBound)
        let initRange = try XCTUnwrap(text.range(of: "public override init("))
        let initBody = String(text[initRange.lowerBound..<guardRange.lowerBound])
        XCTAssertFalse(initBody.contains("genericView"))
        XCTAssertFalse(initBody.contains("mediaPlayer"))
    }

    func testPlayerIsOnlyReadDirectlyWhereItIsKnownToExist() throws {
        let text = try source("SVideoController.swift")
        XCTAssertTrue(text.contains("private var player: (UniversalVideoContentView & NSView) {\n        loadViewIfNeeded()\n        return mediaPlayer\n    }"))
        XCTAssertTrue(text.contains("if isLoaded() {\n            mediaPlayer.pause()\n        }"))
        XCTAssertTrue(text.contains("if let endPlaybackId, let mediaPlayer {"))
        XCTAssertFalse(text.contains("        mediaPlayer.play()"))
        XCTAssertFalse(text.contains("        mediaPlayer.togglePlayPause()"))
    }
}
