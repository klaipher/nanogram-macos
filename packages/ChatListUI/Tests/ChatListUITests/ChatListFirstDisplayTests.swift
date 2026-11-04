import XCTest
import Postbox
import TelegramCore
@testable import ChatListUI

final class ChatListFirstDisplayTests: XCTestCase {
    func testLoadingPlaceholderIsNotReady() {
        XCTAssertFalse(ChatListReadiness.isReady(isLoading: true, hasContent: false))
    }

    func testContentIsReadyEvenWhileStillLoading() {
        XCTAssertTrue(ChatListReadiness.isReady(isLoading: true, hasContent: true))
    }

    func testDefinitivelyEmptyIsReady() {
        XCTAssertTrue(ChatListReadiness.isReady(isLoading: false, hasContent: false))
    }

    func testOnlyPlainListWaitsForBanners() {
        XCTAssertTrue(ChatListFirstDisplayPolicy.waitsForBanners(mode: .plain))
        XCTAssertFalse(ChatListFirstDisplayPolicy.waitsForBanners(mode: .filter(1)))
        XCTAssertFalse(ChatListFirstDisplayPolicy.waitsForBanners(mode: .folder(.archive)))
    }

    func testCacheKeepsMostRecentlyUsed() {
        var cache = ChatListRecentViewCache<Int, String>(capacity: 3)
        cache.put(1, "a")
        cache.put(2, "b")
        cache.put(3, "c")
        XCTAssertEqual(cache.get(1), "a")
        cache.put(4, "d")
        XCTAssertNil(cache.get(2))
        XCTAssertEqual(cache.get(1), "a")
        XCTAssertEqual(cache.get(3), "c")
        XCTAssertEqual(cache.get(4), "d")
        XCTAssertEqual(cache.count, 3)
    }

    func testCachePutReplacesExistingKey() {
        var cache = ChatListRecentViewCache<Int, String>(capacity: 2)
        cache.put(1, "a")
        cache.put(1, "b")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.get(1), "b")
    }

    func testCacheClearsUnderPressure() {
        var cache = ChatListRecentViewCache<Int, String>(capacity: 3)
        cache.put(1, "a")
        cache.removeAll()
        XCTAssertNil(cache.get(1))
        XCTAssertEqual(cache.count, 0)
    }
    func testForumListsFallBackSooner() {
        let forumPeerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(1))
        XCTAssertEqual(ChatListReadiness.fallbackDelay(mode: .forum(forumPeerId, false, false)), ChatListReadiness.forumFallbackDelay)
        XCTAssertEqual(ChatListReadiness.fallbackDelay(mode: .savedMessagesChats(peerId: forumPeerId)), ChatListReadiness.forumFallbackDelay)
        XCTAssertEqual(ChatListReadiness.fallbackDelay(mode: .plain), ChatListReadiness.defaultFallbackDelay)
        XCTAssertLessThan(ChatListReadiness.forumFallbackDelay, ChatListReadiness.defaultFallbackDelay)
    }

    func testPendingForumPushCancelsOnOtherPeerOrFolderChange() {
        let forumPeerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(1))
        let otherPeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(2))
        let forum: PeerListMode = .forum(forumPeerId, false, false)
        XCTAssertTrue(ChatListPendingPushPolicy.cancels(pendingMode: forum, newLocationPeerId: otherPeerId, folderChanged: false))
        XCTAssertFalse(ChatListPendingPushPolicy.cancels(pendingMode: forum, newLocationPeerId: forumPeerId, folderChanged: false))
        XCTAssertFalse(ChatListPendingPushPolicy.cancels(pendingMode: forum, newLocationPeerId: nil, folderChanged: false))
        XCTAssertTrue(ChatListPendingPushPolicy.cancels(pendingMode: forum, newLocationPeerId: nil, folderChanged: true))
        XCTAssertTrue(ChatListPendingPushPolicy.cancels(pendingMode: .savedMessagesChats(peerId: forumPeerId), newLocationPeerId: otherPeerId, folderChanged: false))
        XCTAssertFalse(ChatListPendingPushPolicy.cancels(pendingMode: .folder(.archive), newLocationPeerId: otherPeerId, folderChanged: true))
    }

    func testCacheReplaysOnlyForPlainInitialRequest() {
        XCTAssertTrue(ChatListCachedReplay.usesCache(isInitialRequest: true, hasScrollPosition: false))
        XCTAssertFalse(ChatListCachedReplay.usesCache(isInitialRequest: true, hasScrollPosition: true))
        XCTAssertFalse(ChatListCachedReplay.usesCache(isInitialRequest: false, hasScrollPosition: false))
    }

    func testCachedEntryExpires() {
        var cache = ChatListRecentViewCache<Int, String>(capacity: 3)
        cache.put(1, "a", at: 100)
        XCTAssertEqual(cache.fresh(1, now: 100 + ChatListCachedReplay.maxAge, maxAge: ChatListCachedReplay.maxAge), "a")
        XCTAssertNil(cache.fresh(1, now: 100 + ChatListCachedReplay.maxAge + 1, maxAge: ChatListCachedReplay.maxAge))
        XCTAssertNil(cache.fresh(2, now: 100, maxAge: ChatListCachedReplay.maxAge))
        cache.put(1, "b", at: 200)
        XCTAssertEqual(cache.fresh(1, now: 210, maxAge: ChatListCachedReplay.maxAge), "b")
    }

    func testCachedValueIsDroppedOnceLiveArrives() {
        var gate = ChatListCachedReplayGate()
        gate.liveArrived()
        XCTAssertFalse(gate.shouldEmitCached())
    }

    func testCachedValueIsEmittedOnceWhenLiveIsSlow() {
        var gate = ChatListCachedReplayGate()
        XCTAssertTrue(gate.shouldEmitCached())
        XCTAssertFalse(gate.shouldEmitCached())
        gate.liveArrived()
        XCTAssertFalse(gate.shouldEmitCached())
    }
}
