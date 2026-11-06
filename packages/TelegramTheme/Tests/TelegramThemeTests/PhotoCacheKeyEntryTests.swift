import XCTest
import AppKit
import Postbox
import TelegramCore
@testable import TelegramTheme

final class PhotoCacheKeyEntryTests: XCTestCase {
    private func representation(fileId: Int64) -> TelegramMediaImageRepresentation {
        return TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 100, height: 100), resource: LocalFileMediaResource(fileId: fileId), progressiveSizes: [], immediateThumbnailData: nil)
    }

    private func avatar(peer: Int64, fileId: Int64) -> PhotoCacheKeyEntry {
        return .avatar(PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(peer)), representation(fileId: fileId), nil, NSSize(width: 40, height: 40), 2, false, false)
    }

    func testAvatarKeysOfTheSameResourceAreEqual() {
        XCTAssertEqual(avatar(peer: 1, fileId: 10), avatar(peer: 1, fileId: 10))
        XCTAssertEqual(avatar(peer: 1, fileId: 10).hashValue, avatar(peer: 1, fileId: 10).hashValue)
    }

    func testAvatarKeysOfDifferentResourcesAreNotEqual() {
        XCTAssertNotEqual(avatar(peer: 1, fileId: 10), avatar(peer: 1, fileId: 11))
        XCTAssertNotEqual(avatar(peer: 1, fileId: 10), avatar(peer: 2, fileId: 10))
    }

    func testEmojiKeysCompareByValue() {
        XCTAssertEqual(PhotoCacheKeyEntry.emoji("a", 2), PhotoCacheKeyEntry.emoji("a", 2))
        XCTAssertNotEqual(PhotoCacheKeyEntry.emoji("a", 2), PhotoCacheKeyEntry.emoji("b", 2))
        XCTAssertNotEqual(PhotoCacheKeyEntry.emoji("a", 2), PhotoCacheKeyEntry.emoji("a", 1))
    }

    func testKeysAsAnyHashableMatchTheirOwnKind() {
        XCTAssertEqual(AnyHashable(avatar(peer: 1, fileId: 10)), AnyHashable(avatar(peer: 1, fileId: 10)))
        XCTAssertNotEqual(AnyHashable(avatar(peer: 1, fileId: 10)), AnyHashable(PhotoCacheKeyEntry.emoji("a", 2)))
    }
}
