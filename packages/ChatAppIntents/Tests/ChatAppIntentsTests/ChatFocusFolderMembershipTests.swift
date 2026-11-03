import XCTest
@testable import ChatAppIntents

final class ChatFocusFolderMembershipTests: XCTestCase {
    private func store() -> ChatFocusFilterStore {
        return ChatFocusFilterStore(defaults: UserDefaults(suiteName: "ChatFocusFolderMembershipTests-\(UUID().uuidString)")!)
    }

    private func rules(_ id: Int32, include: Set<Int64> = [], exclude: Set<Int64> = [], categories: ChatFocusFolderCategories = [], excludeMuted: Bool = false, excludeRead: Bool = false, excludeArchived: Bool = false) -> ChatFocusFolderRules {
        return ChatFocusFolderRules(id: id, includePeerIds: include, excludePeerIds: exclude, categories: categories, excludeMuted: excludeMuted, excludeRead: excludeRead, excludeArchived: excludeArchived)
    }

    private func chat(_ peerIds: [Int64], _ kind: ChatFocusChat.Kind, muted: Bool = false, mention: Bool = false, unread: Bool = true, archived: Bool = false) -> ChatFocusChat {
        return ChatFocusChat(peerIds: peerIds, kind: kind, isMuted: muted, hasUnseenMention: mention, isUnread: unread, isArchived: archived)
    }

    func testNotificationsAreAllowedUntilTheFoldersHaveLoaded() {
        let store = self.store()
        let membership = ChatFocusFolderMembership(store: store, requestFolders: { _ in })
        store.update(ChatFocusFilter(accountIds: [], folders: [.init(accountId: 1, folderId: 3)]))
        let other = self.chat([10], .user(isContact: true))
        XCTAssertFalse(membership.isLoaded(accountId: 1))
        XCTAssertTrue(membership.allows(accountId: 1, chat: other))

        membership.setFolders([self.rules(3, include: [11])], accountId: 1)
        XCTAssertTrue(membership.isLoaded(accountId: 1))
        XCTAssertFalse(membership.allows(accountId: 1, chat: other))
        XCTAssertTrue(membership.allows(accountId: 1, chat: self.chat([11], .user(isContact: true))))
        XCTAssertFalse(membership.allows(accountId: 2, chat: other))
    }

    func testSettingAFolderFilterPrefetchesThatAccountsFolders() {
        let store = self.store()
        var requested: [Int64] = []
        let membership = ChatFocusFolderMembership(store: store, requestFolders: { requested.append($0) })
        store.update(ChatFocusFilter(accountIds: [2], folders: [.init(accountId: 1, folderId: 3), .init(accountId: 2, folderId: 4)]))
        XCTAssertEqual(requested, [1])
        membership.setFolders([self.rules(3)], accountId: 1)
        store.update(ChatFocusFilter(accountIds: [], folders: [.init(accountId: 1, folderId: 5)]))
        XCTAssertEqual(requested, [1])
        store.update(ChatFocusFilter(accountIds: [], folders: []))
        XCTAssertEqual(requested, [1])
        withExtendedLifetime(membership) {}
    }

    func testAFilterSavedBeforeLaunchIsPrefetchedAtStart() {
        let store = self.store()
        store.update(ChatFocusFilter(accountIds: [], folders: [.init(accountId: 7, folderId: 1)]))
        var requested: [Int64] = []
        let membership = ChatFocusFolderMembership(store: store, requestFolders: { requested.append($0) })
        XCTAssertEqual(requested, [7])
        withExtendedLifetime(membership) {}
    }

    func testExcludeMutedReadAndArchived() {
        let all: ChatFocusFolderCategories = [.contacts, .nonContacts, .groups, .channels, .bots]
        let group = ChatFocusChat.Kind.group
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, categories: all), self.chat([1], group, muted: true, archived: true)))

        XCTAssertFalse(ChatFocusFolderMatcher.contains(self.rules(1, categories: all, excludeMuted: true), self.chat([1], group, muted: true)))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, categories: all, excludeMuted: true), self.chat([1], group, muted: true, mention: true)))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, categories: all, excludeMuted: true), self.chat([1], group)))

        XCTAssertFalse(ChatFocusFolderMatcher.contains(self.rules(1, categories: all, excludeRead: true), self.chat([1], group, unread: false)))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, categories: all, excludeRead: true), self.chat([1], group, mention: true, unread: false)))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, categories: all, excludeRead: true), self.chat([1], group)))

        XCTAssertFalse(ChatFocusFolderMatcher.contains(self.rules(1, categories: all, excludeArchived: true), self.chat([1], group, archived: true)))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, include: [1], excludeArchived: true), self.chat([1], group, archived: true)))
    }

    func testContactsAndNonContactsAreDistinguished() {
        let contact = self.chat([1], .user(isContact: true))
        let stranger = self.chat([2], .user(isContact: false))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.contacts]), contact))
        XCTAssertFalse(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.contacts]), stranger))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.nonContacts]), stranger))
        XCTAssertFalse(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.nonContacts]), contact))
        XCTAssertFalse(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.contacts, .nonContacts]), self.chat([3], .bot)))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.bots]), self.chat([3], .bot)))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.channels]), self.chat([4], .channel)))
        XCTAssertFalse(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.groups]), self.chat([4], .channel)))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.channels]), self.chat([5], .community([.groups, .channels]))))
        XCTAssertFalse(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.bots]), self.chat([5], .community([.groups, .channels]))))
    }

    func testSecretChatsMatchIncludeAndExcludeListsByTheirOwnIdAndCategoriesThroughTheirUser() {
        let secret = self.chat([900, 42], .user(isContact: true))
        XCTAssertFalse(ChatFocusFolderMatcher.contains(self.rules(1, include: [42]), secret))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, include: [900]), secret))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.contacts]), secret))
        XCTAssertFalse(ChatFocusFolderMatcher.contains(self.rules(1, categories: [.nonContacts]), secret))
        XCTAssertTrue(ChatFocusFolderMatcher.contains(self.rules(1, exclude: [42], categories: [.contacts]), secret))
        XCTAssertFalse(ChatFocusFolderMatcher.contains(self.rules(1, exclude: [900], categories: [.contacts]), secret))
    }

    func testFoldersLoadForEveryLoggedInAccountNotOnlyTheActiveOne() {
        let store = self.store()
        var observed: [Int64] = []
        var updates: [Int64: ([ChatFocusFolderRules]) -> Void] = [:]
        var cancelled: [Int64] = []
        let loggedIn: Set<Int64> = [1, 2]
        let feeds = ChatFocusFolderFeeds(store: store, schedule: { $0() }, observeFolders: { accountId, update in
            guard loggedIn.contains(accountId) else {
                return nil
            }
            observed.append(accountId)
            updates[accountId] = update
            return { cancelled.append(accountId) }
        })
        store.update(ChatFocusFilter(accountIds: [], folders: [.init(accountId: 2, folderId: 4), .init(accountId: 3, folderId: 5)]))
        XCTAssertEqual(observed, [2])
        updates[2]?([self.rules(4, include: [11])])
        XCTAssertTrue(feeds.membership.isLoaded(accountId: 2))
        XCTAssertFalse(feeds.membership.allows(accountId: 2, chat: self.chat([10], .group)))
        XCTAssertTrue(feeds.membership.allows(accountId: 2, chat: self.chat([11], .group)))
        XCTAssertFalse(feeds.membership.isLoaded(accountId: 3))
        XCTAssertTrue(cancelled.isEmpty)
    }
}
