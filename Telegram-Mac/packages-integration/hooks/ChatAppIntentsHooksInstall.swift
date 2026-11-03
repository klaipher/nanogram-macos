import Cocoa
import SwiftSignalKit
import Postbox
import TelegramCore
import ChatAppIntents
#if canImport(AppIntents)
import AppIntents

@available(macOS 14.0, *)
struct NanogramAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        return [ChatAppIntentsPackage.self]
    }
}

@available(macOS 14.0, *)
struct ChatAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenChatIntent(), phrases: ["Open a chat in \(.applicationName)"], shortTitle: "Open Chat", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: SendMessageIntent(), phrases: ["Send a message with \(.applicationName)"], shortTitle: "Send Message", systemImageName: "paperplane")
    }
}
#endif

private func onMain<T>(_ f: () -> T) -> T {
    if Thread.isMainThread {
        return f()
    } else {
        return DispatchQueue.main.sync(execute: f)
    }
}

private func firstValue<T>(_ signal: Signal<T, NoError>) async -> T? {
    return await withCheckedContinuation { continuation in
        let lock = NSLock()
        var finished = false
        func finish(_ value: T?) {
            lock.lock()
            let first = !finished
            finished = true
            lock.unlock()
            if first {
                continuation.resume(returning: value)
            }
        }
        _ = (signal |> take(1)).start(next: { value in
            finish(value)
        }, completed: {
            finish(nil)
        })
    }
}

private func accountContexts() -> [AccountContext] {
    return onMain {
        var result: [AccountContext] = []
        appDelegate?.enumerateAccountContexts { context in
            result.append(context)
        }
        return result
    }
}

private func accountContext(_ accountId: Int64) -> AccountContext? {
    return accountContexts().first(where: { $0.account.id.int64 == accountId })
}

private final class AppChatIntentsDataSource: ChatIntentsDataSource {
    var isLocked: Bool {
        return onMain {
            return appDelegate?.sharedApplicationContextValue?.notificationManager._lockedValue.passcodeLock ?? true
        }
    }

    private func accountTitle(_ context: AccountContext) async -> String {
        let peer = await firstValue(context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.peerId)))
        return peer??._asPeer().displayTitle ?? ""
    }

    private func record(_ context: AccountContext, peer: Peer?, accountTitle: String) -> ChatIntentRecord? {
        guard let peer = peer else {
            return nil
        }
        return ChatIntentRecord(id: .init(accountId: context.account.id.int64, peerId: peer.id.toInt64()), title: peer.displayTitle, accountTitle: accountTitle)
    }

    func recentChats(limit: Int) async -> [ChatIntentRecord] {
        var result: [ChatIntentRecord] = []
        for context in accountContexts() {
            let title = await self.accountTitle(context)
            if let list = await firstValue(context.engine.messages.chatList(group: .root, count: limit)) {
                for item in list.items.reversed() {
                    if let record = self.record(context, peer: item.renderedPeer.chatMainPeer?._asPeer(), accountTitle: title) {
                        result.append(record)
                    }
                }
            }
        }
        return Array(result.prefix(limit))
    }

    func searchChats(query: String, limit: Int) async -> [ChatIntentRecord] {
        var result: [ChatIntentRecord] = []
        for context in accountContexts() {
            let title = await self.accountTitle(context)
            if let peers = await firstValue(context.engine.contacts.searchLocalPeers(query: query)) {
                for peer in peers {
                    if let record = self.record(context, peer: peer.chatMainPeer?._asPeer(), accountTitle: title) {
                        result.append(record)
                    }
                }
            }
        }
        return Array(result.prefix(limit))
    }

    func chats(ids: [ChatIntentRecord.ID]) async -> [ChatIntentRecord] {
        var result: [ChatIntentRecord] = []
        for id in ids {
            guard let context = accountContext(id.accountId) else {
                continue
            }
            let title = await self.accountTitle(context)
            let peer = await firstValue(context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: PeerId(id.peerId))))
            if let record = self.record(context, peer: peer??._asPeer(), accountTitle: title) {
                result.append(record)
            }
        }
        return result
    }

    func allFolders() async -> [ChatIntentFolder] {
        var result: [ChatIntentFolder] = []
        for context in accountContexts() {
            let title = await self.accountTitle(context)
            let filters = await firstValue(context.engine.peers.currentChatListFilters()) ?? []
            for filter in filters {
                if case let .filter(id, folderTitle, _, _) = filter {
                    result.append(ChatIntentFolder(id: .init(accountId: context.account.id.int64, folderId: id), title: folderTitle.text, accountTitle: title))
                }
            }
        }
        return result
    }

    func allAccounts() async -> [ChatIntentAccount] {
        var result: [ChatIntentAccount] = []
        for context in accountContexts() {
            result.append(ChatIntentAccount(id: context.account.id.int64, title: await self.accountTitle(context)))
        }
        return result
    }

    func openChat(_ id: ChatIntentRecord.ID) async -> Bool {
        return await MainActor.run {
            guard let context = accountContext(id.accountId) else {
                return false
            }
            let peerId = PeerId(id.peerId)
            NSApp.activate(ignoringOtherApps: true)
            if appDelegate?.activeContext(for: nil)?.account.id == context.account.id {
                navigateToChat(navigation: context.bindings.rootNavigation(), context: context, chatLocation: .peer(peerId))
            } else {
                context.sharedContext.switchToAccount(id: context.account.id, action: .chat(peerId, necessary: true))
            }
            return true
        }
    }

    func sendMessage(_ text: String, to id: ChatIntentRecord.ID) async -> Bool {
        guard let context = accountContext(id.accountId) else {
            return false
        }
        let message = EnqueueMessage.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        let ids = await firstValue(enqueueMessages(account: context.account, peerId: PeerId(id.peerId), messages: [message]))
        return ids?.contains(where: { $0 != nil }) ?? false
    }
}

final class AppChatFocusFolders {
    static let shared = AppChatFocusFolders()

    private(set) var membership: ChatFocusFolderMembership!
    private let disposables = DisposableDict<Int64>()

    private init() {
        self.membership = ChatFocusFolderMembership(store: ChatFocusFilterStore.shared, requestFolders: { accountId in
            DispatchQueue.main.async {
                AppChatFocusFolders.shared.subscribe(accountId)
            }
        })
    }

    private func subscribe(_ accountId: Int64) {
        guard let context = accountContext(accountId) else {
            self.membership.clearFolders(accountId: accountId)
            return
        }
        self.disposables.set(context.engine.peers.updatedChatListFilters().start(next: { [weak self] filters in
            self?.membership.setFolders(filters.compactMap(AppChatFocusFolders.rules), accountId: accountId)
        }), forKey: accountId)
    }

    private static func rules(_ filter: ChatListFilter) -> ChatFocusFolderRules? {
        guard case let .filter(id, _, _, data) = filter else {
            return nil
        }
        var categories: ChatFocusFolderCategories = []
        if data.categories.contains(.contacts) {
            categories.insert(.contacts)
        }
        if data.categories.contains(.nonContacts) {
            categories.insert(.nonContacts)
        }
        if data.categories.contains(.groups) {
            categories.insert(.groups)
        }
        if data.categories.contains(.channels) {
            categories.insert(.channels)
        }
        if data.categories.contains(.bots) {
            categories.insert(.bots)
        }
        return ChatFocusFolderRules(id: id, includePeerIds: Set(data.includePeers.peers.map { $0.toInt64() }), excludePeerIds: Set(data.excludePeers.map { $0.toInt64() }), categories: categories, excludeMuted: data.excludeMuted, excludeRead: data.excludeRead, excludeArchived: data.excludeArchived)
    }

    func needsChatDetails(accountId: Int64) -> Bool {
        return self.membership.needsChatDetails(accountId: accountId)
    }

    static func chat(transaction: Transaction, peerId: PeerId, isMuted: Bool, hasUnseenMention: Bool) -> ChatFocusChat {
        var peerIds: [Int64] = [peerId.toInt64()]
        var peer = transaction.getPeer(peerId)
        if let secretChat = peer as? TelegramSecretChat {
            peerIds.append(secretChat.regularPeerId.toInt64())
            peer = transaction.getPeer(secretChat.regularPeerId)
        }
        let kind: ChatFocusChat.Kind
        if let user = peer as? TelegramUser {
            if user.botInfo != nil {
                kind = .bot
            } else {
                kind = .user(isContact: transaction.isPeerContact(peerId: user.id))
            }
        } else if let channel = peer as? TelegramChannel {
            if case .broadcast = channel.info {
                kind = .channel
            } else {
                kind = .group
            }
        } else if peer is TelegramCommunity {
            kind = .community([.groups, .channels])
        } else {
            kind = .group
        }
        let isArchived = transaction.getPeerChatListIndex(peerId)?.0 == Namespaces.PeerGroup.archive
        return ChatFocusChat(peerIds: peerIds, kind: kind, isMuted: isMuted, hasUnseenMention: hasUnseenMention, isUnread: true, isArchived: isArchived)
    }

    func allows(accountId: Int64, chat: ChatFocusChat?, peerId: PeerId) -> Bool {
        if let chat = chat {
            return self.membership.allows(accountId: accountId, chat: chat)
        }
        if self.needsChatDetails(accountId: accountId) {
            return true
        }
        return self.membership.allows(accountId: accountId, chat: ChatFocusChat(peerIds: [peerId.toInt64()], kind: .group, isMuted: false, hasUnseenMention: false, isUnread: true, isArchived: false))
    }
}

private let appChatIntentsDataSource = AppChatIntentsDataSource()

func installChatAppIntentsHooks() {
    ChatIntentsBridge.dataSource = appChatIntentsDataSource
    _ = AppChatFocusFolders.shared
}
