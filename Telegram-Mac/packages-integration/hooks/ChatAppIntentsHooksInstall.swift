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

final class ChatFocusFolderMembership {
    static let shared = ChatFocusFolderMembership()

    private let lock = NSLock()
    private var filters: [Int64: [ChatListFilter]] = [:]
    private var refreshed: [Int64: Double] = [:]
    private let disposables = DisposableDict<Int64>()

    private func refreshIfNeeded(_ account: Account) {
        let accountId = account.id.int64
        let now = CFAbsoluteTimeGetCurrent()
        self.lock.lock()
        let last = self.refreshed[accountId]
        if let last = last, now - last < 60 {
            self.lock.unlock()
            return
        }
        self.refreshed[accountId] = now
        self.lock.unlock()
        self.disposables.set((TelegramEngine(account: account).peers.currentChatListFilters() |> take(1)).start(next: { [weak self] filters in
            guard let self = self else {
                return
            }
            self.lock.lock()
            self.filters[accountId] = filters
            self.lock.unlock()
        }), forKey: accountId)
    }

    func allows(account: Account, peer: Peer?, peerId: PeerId) -> Bool {
        let accountId = account.id.int64
        let store = ChatFocusFilterStore.shared
        guard store.needsFolderMembership(accountId: accountId) else {
            return store.allows(accountId: accountId, peerId: peerId.toInt64(), folderIds: Set())
        }
        self.refreshIfNeeded(account)
        self.lock.lock()
        let filters = self.filters[accountId] ?? []
        self.lock.unlock()
        var folderIds = Set<Int32>()
        for filter in filters {
            if case let .filter(id, _, _, data) = filter, ChatFocusFolderMembership.folder(data, contains: peer, peerId: peerId) {
                folderIds.insert(id)
            }
        }
        return store.allows(accountId: accountId, peerId: peerId.toInt64(), folderIds: folderIds)
    }

    private static func folder(_ data: ChatListFilterData, contains peer: Peer?, peerId: PeerId) -> Bool {
        if data.excludePeers.contains(peerId) {
            return false
        }
        if data.includePeers.peers.contains(peerId) {
            return true
        }
        guard let peer = peer else {
            return false
        }
        if let user = peer as? TelegramUser {
            if user.botInfo != nil {
                return data.categories.contains(.bots)
            }
            return data.categories.contains(.contacts) || data.categories.contains(.nonContacts)
        } else if let channel = peer as? TelegramChannel {
            if case .broadcast = channel.info {
                return data.categories.contains(.channels)
            }
            return data.categories.contains(.groups)
        } else if peer is TelegramGroup {
            return data.categories.contains(.groups)
        }
        return false
    }
}

private let appChatIntentsDataSource = AppChatIntentsDataSource()

func installChatAppIntentsHooks() {
    ChatIntentsBridge.dataSource = appChatIntentsDataSource
}
