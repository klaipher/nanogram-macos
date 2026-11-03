import Foundation

public struct ChatFocusFolderCategories: OptionSet, Equatable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let contacts = ChatFocusFolderCategories(rawValue: 1 << 0)
    public static let nonContacts = ChatFocusFolderCategories(rawValue: 1 << 1)
    public static let groups = ChatFocusFolderCategories(rawValue: 1 << 2)
    public static let channels = ChatFocusFolderCategories(rawValue: 1 << 3)
    public static let bots = ChatFocusFolderCategories(rawValue: 1 << 4)
}

public struct ChatFocusFolderRules: Equatable {
    public let id: Int32
    public let includePeerIds: Set<Int64>
    public let excludePeerIds: Set<Int64>
    public let categories: ChatFocusFolderCategories
    public let excludeMuted: Bool
    public let excludeRead: Bool
    public let excludeArchived: Bool

    public init(id: Int32, includePeerIds: Set<Int64>, excludePeerIds: Set<Int64>, categories: ChatFocusFolderCategories, excludeMuted: Bool, excludeRead: Bool, excludeArchived: Bool) {
        self.id = id
        self.includePeerIds = includePeerIds
        self.excludePeerIds = excludePeerIds
        self.categories = categories
        self.excludeMuted = excludeMuted
        self.excludeRead = excludeRead
        self.excludeArchived = excludeArchived
    }
}

public struct ChatFocusChat: Equatable {
    public enum Kind: Equatable {
        case user(isContact: Bool)
        case bot
        case group
        case channel
        case community(ChatFocusFolderCategories)
    }

    public let peerIds: [Int64]
    public let kind: Kind
    public let isMuted: Bool
    public let hasUnseenMention: Bool
    public let isUnread: Bool
    public let isArchived: Bool

    public init(peerIds: [Int64], kind: Kind, isMuted: Bool, hasUnseenMention: Bool, isUnread: Bool, isArchived: Bool) {
        self.peerIds = peerIds
        self.kind = kind
        self.isMuted = isMuted
        self.hasUnseenMention = hasUnseenMention
        self.isUnread = isUnread
        self.isArchived = isArchived
    }
}

public enum ChatFocusFolderMatcher {
    public static func contains(_ rules: ChatFocusFolderRules, _ chat: ChatFocusChat) -> Bool {
        if chat.peerIds.contains(where: { rules.excludePeerIds.contains($0) }) {
            return false
        }
        if chat.peerIds.contains(where: { rules.includePeerIds.contains($0) }) {
            return true
        }
        if rules.excludeArchived && chat.isArchived {
            return false
        }
        if rules.excludeRead && !chat.isUnread && !chat.hasUnseenMention {
            return false
        }
        if rules.excludeMuted && chat.isMuted && !chat.hasUnseenMention {
            return false
        }
        switch chat.kind {
        case let .user(isContact):
            return rules.categories.contains(isContact ? .contacts : .nonContacts)
        case .bot:
            return rules.categories.contains(.bots)
        case .group:
            return rules.categories.contains(.groups)
        case .channel:
            return rules.categories.contains(.channels)
        case let .community(categories):
            return !categories.intersection(rules.categories).isEmpty
        }
    }
}

public final class ChatFocusFolderMembership {
    private let store: ChatFocusFilterStore
    private let requestFolders: (Int64) -> Void
    private let lock = NSLock()
    private var folders: [Int64: [ChatFocusFolderRules]] = [:]
    private var requested: Set<Int64> = []
    private var observer: NSObjectProtocol?

    public init(store: ChatFocusFilterStore, requestFolders: @escaping (Int64) -> Void) {
        self.store = store
        self.requestFolders = requestFolders
        self.observer = NotificationCenter.default.addObserver(forName: ChatFocusFilterStore.didChangeNotification, object: store, queue: nil, using: { [weak self] _ in
            self?.prefetch()
        })
        self.prefetch()
    }

    deinit {
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public var accountsNeedingFolders: [Int64] {
        let filter = self.store.current
        var result: [Int64] = []
        for folder in filter.folders where !filter.accountIds.contains(folder.accountId) && !result.contains(folder.accountId) {
            result.append(folder.accountId)
        }
        return result
    }

    private func prefetch() {
        var toRequest: [Int64] = []
        self.lock.lock()
        for accountId in self.accountsNeedingFolders where self.folders[accountId] == nil && !self.requested.contains(accountId) {
            self.requested.insert(accountId)
            toRequest.append(accountId)
        }
        self.lock.unlock()
        for accountId in toRequest {
            self.requestFolders(accountId)
        }
    }

    public func setFolders(_ folders: [ChatFocusFolderRules], accountId: Int64) {
        self.lock.lock()
        self.folders[accountId] = folders
        self.requested.remove(accountId)
        self.lock.unlock()
    }

    public func clearFolders(accountId: Int64) {
        self.lock.lock()
        self.folders.removeValue(forKey: accountId)
        self.requested.remove(accountId)
        self.lock.unlock()
    }

    public func isLoaded(accountId: Int64) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.folders[accountId] != nil
    }

    public func needsChatDetails(accountId: Int64) -> Bool {
        return self.store.needsFolderMembership(accountId: accountId)
    }

    public func allows(accountId: Int64, chat: ChatFocusChat) -> Bool {
        guard self.store.needsFolderMembership(accountId: accountId) else {
            return self.store.allows(accountId: accountId, peerId: chat.peerIds.first ?? 0, folderIds: Set())
        }
        self.lock.lock()
        let folders = self.folders[accountId]
        self.lock.unlock()
        guard let folders = folders else {
            self.prefetch()
            return true
        }
        let folderIds = Set(folders.filter { ChatFocusFolderMatcher.contains($0, chat) }.map { $0.id })
        return self.store.allows(accountId: accountId, peerId: chat.peerIds.first ?? 0, folderIds: folderIds)
    }
}
