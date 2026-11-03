import XCTest
import AppKit
import TGUIKit
import TelegramTheme
import Postbox
import TelegramCore
@testable import ChatListUI

final class ChatListStateProjectionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UITestBootstrap.install()
    }

    private func base() -> PeerListState {
        return PeerListState(proxySettings: .defaultSettings, connectionStatus: .online(proxyAddress: nil), splitState: .dual, searchState: .None, peer: nil, forumPeer: nil, mode: .plain, activities: .init(activities: [:]), appear: .normal, controllerAppear: .normal, hiddenItems: .default, selectedForum: nil, stories: nil, isContacts: false, filterData: FilterData(requestTimestamp: 10), presentation: theme, privacy: nil, displaySavedAsTopics: false)
    }

    func testFieldsTheChatListDoesNotReadDoNotRebuildIt() {
        let state = base()
        var other = state
        other.connectionStatus = .waitingForNetwork
        other.searchQuery = "query"
        other.searchState = .Focus
        other.hasDownloads = true
        other.isContacts = true
        other.filterData = FilterData(filter: state.filterData.filter, tabs: state.filterData.tabs, sidebar: true, showTags: state.filterData.showTags, request: .Initial(100, nil), badges: .init(total: 42, filters: []), requestTimestamp: state.filterData.requestTimestamp, isTop: false)
        XCTAssertNotEqual(state, other)
        XCTAssertEqual(ChatListStateProjection(state), ChatListStateProjection(other))
    }

    func testFieldsTheChatListReadsStillRebuildIt() {
        let state = base()
        var appear = state
        appear.appear = .short
        XCTAssertNotEqual(ChatListStateProjection(state), ChatListStateProjection(appear))

        var split = state
        split.splitState = .single
        XCTAssertNotEqual(ChatListStateProjection(state), ChatListStateProjection(split))

        var tags = state
        tags.filterData = FilterData(showTags: true, requestTimestamp: 10)
        XCTAssertNotEqual(ChatListStateProjection(state), ChatListStateProjection(tags))

        var request = state
        request.filterData = FilterData(requestTimestamp: 11)
        XCTAssertNotEqual(ChatListStateProjection(state), ChatListStateProjection(request))

        var controllerAppear = state
        controllerAppear.controllerAppear = .short
        XCTAssertNotEqual(ChatListStateProjection(state), ChatListStateProjection(controllerAppear))
    }

    func testTypingDoesNotChangeTheProjectionTheActivityFeedDecides() {
        let state = base()
        var typing = state
        typing.activities = .init(activities: [PeerActivitySpace(peerId: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(5)), category: .global): []])
        XCTAssertEqual(ChatListStateProjection(state), ChatListStateProjection(typing))
    }

    private func space(_ id: Int64, _ category: PeerActivitySpace.Category = .global) -> PeerActivitySpace {
        return PeerActivitySpace(peerId: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(id)), category: category)
    }

    private func typing(_ id: Int64, by userId: Int64, timestamp: Int32 = 0) -> PeerListState.InputActivities.Activity {
        let user = TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(userId)), accessHash: nil, firstName: "U\(userId)", lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        return .init(user, .typingText)
    }

    func testTypingOutsideTheLoadedRowsDoesNotRebuildTheList() {
        let feed = ChatListActivityFeed()
        XCTAssertTrue(feed.update(.init(activities: [:])))
        let loaded: Set<PeerActivitySpace> = [space(1), space(2)]
        XCTAssertEqual(feed.activities(loading: loaded), .init(activities: [:]))
        var rebuilds = 0
        for index in 0 ..< 100 {
            var activities: [PeerActivitySpace: [PeerListState.InputActivities.Activity]] = [:]
            if index % 2 == 0 {
                activities[space(Int64(100 + index))] = [typing(Int64(100 + index), by: 7)]
            }
            activities[space(1, .voiceChat)] = index % 3 == 0 ? [typing(1, by: 8)] : nil
            if feed.update(.init(activities: activities)) {
                rebuilds += 1
            }
        }
        XCTAssertEqual(rebuilds, 0)
        XCTAssertTrue(feed.update(.init(activities: [space(2): [typing(2, by: 9)]])))
        XCTAssertEqual(feed.activities(loading: loaded).activities[space(2)], [typing(2, by: 9)])
        XCTAssertFalse(feed.update(.init(activities: [space(2): [typing(2, by: 9)]])))
        XCTAssertTrue(feed.update(.init(activities: [:])))
    }

    func testAChatPagedInWhileSomeoneTypesShowsTheActivity() {
        let feed = ChatListActivityFeed()
        _ = feed.update(.init(activities: [:]))
        _ = feed.activities(loading: [space(1)])
        XCTAssertFalse(feed.update(.init(activities: [space(50): [typing(50, by: 3)]])))
        XCTAssertEqual(feed.activities(loading: [space(1), space(50)]).activities[space(50)], [typing(50, by: 3)])
        XCTAssertTrue(feed.update(.init(activities: [:])))
    }
}
