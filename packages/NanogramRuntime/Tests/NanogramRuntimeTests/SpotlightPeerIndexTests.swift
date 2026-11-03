import CoreSpotlight
import XCTest
@testable import NanogramRuntime

private final class FakeIndex: SpotlightIndexing {
    var items: [String: CSSearchableItem] = [:]
    var indexCalls = 0
    var deleteAllCalls = 0

    func indexSearchableItems(_ items: [CSSearchableItem], completionHandler: (@Sendable (Error?) -> Void)?) {
        indexCalls += 1
        for item in items {
            self.items[item.uniqueIdentifier] = item
        }
        completionHandler?(nil)
    }

    func deleteSearchableItems(withIdentifiers identifiers: [String], completionHandler: (@Sendable (Error?) -> Void)?) {
        for identifier in identifiers {
            items.removeValue(forKey: identifier)
        }
        completionHandler?(nil)
    }

    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String], completionHandler: (@Sendable (Error?) -> Void)?) {
        items = items.filter { !domainIdentifiers.contains($0.value.domainIdentifier ?? "") }
        completionHandler?(nil)
    }

    func deleteAllSearchableItems(completionHandler: (@Sendable (Error?) -> Void)?) {
        deleteAllCalls += 1
        items.removeAll()
        completionHandler?(nil)
    }
}

final class SpotlightPeerIndexTests: XCTestCase {
    private func entry(_ id: Int64, _ title: String) -> SpotlightPeerEntry {
        return SpotlightPeerEntry(peerId: id, uniqueIdentifier: "accountId=1&source=peerId:\(id)", title: title, accountTitle: "me", avatarPNG: nil)
    }

    func testSameCountDifferentPeersIsAChange() {
        XCTAssertTrue(SpotlightPeerEntry.sameIndexContent([entry(1, "A"), entry(2, "B")], [entry(1, "A"), entry(2, "B")]))
        XCTAssertFalse(SpotlightPeerEntry.sameIndexContent([entry(1, "A"), entry(2, "B")], [entry(1, "A"), entry(3, "C")]))
        XCTAssertFalse(SpotlightPeerEntry.sameIndexContent([entry(1, "A")], [entry(1, "Renamed")]))
    }

    func testItemsAreContactsInTheAccountDomainWithExpiry() {
        let index = FakeIndex()
        let account = SpotlightPeerIndex(index: index, accountId: 1)
        account.update([entry(10, "Alice")])
        let item = index.items["accountId=1&source=peerId:10"]
        XCTAssertEqual(item?.domainIdentifier, "account.1")
        XCTAssertEqual(item?.attributeSet.displayName, "Alice")
        XCTAssertNotNil(item?.expirationDate)
        if #available(macOS 11.0, *) {
            XCTAssertEqual(item?.attributeSet.contentType, UTType.contact.identifier)
        }
    }

    func testRemovedPeersAreDeletedAndUnchangedListsAreNotReindexed() {
        let index = FakeIndex()
        let account = SpotlightPeerIndex(index: index, accountId: 1)
        account.update([entry(10, "Alice"), entry(11, "Bob")])
        account.update([entry(10, "Alice"), entry(11, "Bob")])
        XCTAssertEqual(index.indexCalls, 1)
        account.update([entry(10, "Alice"), entry(12, "Carol")])
        XCTAssertEqual(Set(index.items.keys), ["accountId=1&source=peerId:10", "accountId=1&source=peerId:12"])
    }

    func testLockAndLogoutRemoveTheDomainAndUnlockReindexes() {
        let index = FakeIndex()
        let other = SpotlightPeerIndex(index: index, accountId: 2)
        other.update([SpotlightPeerEntry(peerId: 5, uniqueIdentifier: "accountId=2&source=peerId:5", title: "Other", accountTitle: "x", avatarPNG: nil)])
        let account = SpotlightPeerIndex(index: index, accountId: 1)
        account.update([entry(10, "Alice")])
        account.setLocked(true)
        XCTAssertEqual(Set(index.items.keys), ["accountId=2&source=peerId:5"])
        account.update([entry(10, "Alice"), entry(11, "Bob")])
        XCTAssertEqual(index.items.count, 1)
        account.setLocked(false)
        XCTAssertEqual(index.items.count, 3)
        account.removeAll()
        XCTAssertEqual(Set(index.items.keys), ["accountId=2&source=peerId:5"])
    }

    func testLaunchResetClearsItemsFromEarlierLaunchesOnce() {
        let index = FakeIndex()
        SpotlightPeerIndex.resetLaunchState()
        SpotlightPeerIndex.removeItemsFromEarlierLaunches(index)
        SpotlightPeerIndex.removeItemsFromEarlierLaunches(index)
        XCTAssertEqual(index.deleteAllCalls, 1)
    }
}
