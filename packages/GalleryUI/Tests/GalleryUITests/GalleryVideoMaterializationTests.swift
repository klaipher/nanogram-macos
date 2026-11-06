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

    func testRotateClosureStartsLoadingBeforeTheMaterializeGuard() throws {
        let text = try source("MGalleryVideoItem.swift")
        let startRange = try XCTUnwrap(text.range(of: "self.controller.startLoading()"))
        let guardRange = try XCTUnwrap(text.range(of: "GalleryVideoMaterialization.shouldMaterialize"))
        XCTAssertTrue(startRange.lowerBound < guardRange.lowerBound)
    }

    func testStartLoadingIsIdempotentAndDoesNotCreateThePlayer() throws {
        let text = try source("SVideoController.swift")
        let startRange = try XCTUnwrap(text.range(of: "public func startLoading() {"))
        let viewDidLoadRange = try XCTUnwrap(text.range(of: "public override func viewDidLoad() {"))
        XCTAssertTrue(startRange.lowerBound < viewDidLoadRange.lowerBound)
        let body = String(text[startRange.lowerBound..<viewDidLoadRange.lowerBound])
        XCTAssertTrue(body.contains("if didStartLoading {\n            return\n        }\n        didStartLoading = true"))
        XCTAssertTrue(body.contains("preloadVideoResource"))
        XCTAssertTrue(body.contains("minimizedHLSQualityPreloadData"))
        XCTAssertTrue(body.contains("adMessages(peerId:"))
        XCTAssertTrue(body.contains("adContext.state, playerStatus.get()"))
        XCTAssertFalse(body.contains("mediaPlayer"))
        XCTAssertFalse(body.contains("genericView"))
        XCTAssertFalse(body.contains("loadViewIfNeeded"))
        XCTAssertFalse(body.contains(", status)"))
    }

    func testViewDidLoadStartsLoadingAndFeedsThePlayerStatus() throws {
        let text = try source("SVideoController.swift")
        let range = try XCTUnwrap(text.range(of: "public override func viewDidLoad() {"))
        let body = String(text[range.lowerBound...])
        let startRange = try XCTUnwrap(body.range(of: "startLoading()"))
        let statusRange = try XCTUnwrap(body.range(of: "playerStatus.set(mediaPlayer.status)"))
        XCTAssertTrue(startRange.lowerBound < statusRange.lowerBound)
    }
}
