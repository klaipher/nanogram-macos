import Foundation

public struct ChatIntentRecord: Equatable, Sendable {
    public struct ID: Hashable, Codable, Sendable {
        public let accountId: Int64
        public let peerId: Int64

        public init(accountId: Int64, peerId: Int64) {
            self.accountId = accountId
            self.peerId = peerId
        }

        public init?(string: String) {
            let parts = string.split(separator: ":")
            guard parts.count == 2, let accountId = Int64(parts[0]), let peerId = Int64(parts[1]) else {
                return nil
            }
            self.init(accountId: accountId, peerId: peerId)
        }

        public var string: String {
            return "\(self.accountId):\(self.peerId)"
        }
    }

    public let id: ID
    public let title: String
    public let accountTitle: String

    public init(id: ID, title: String, accountTitle: String) {
        self.id = id
        self.title = title
        self.accountTitle = accountTitle
    }
}

public struct ChatIntentFolder: Equatable, Sendable {
    public struct ID: Hashable, Codable, Sendable {
        public let accountId: Int64
        public let folderId: Int32

        public init(accountId: Int64, folderId: Int32) {
            self.accountId = accountId
            self.folderId = folderId
        }

        public init?(string: String) {
            let parts = string.split(separator: ":")
            guard parts.count == 2, let accountId = Int64(parts[0]), let folderId = Int32(parts[1]) else {
                return nil
            }
            self.init(accountId: accountId, folderId: folderId)
        }

        public var string: String {
            return "\(self.accountId):\(self.folderId)"
        }
    }

    public let id: ID
    public let title: String
    public let accountTitle: String

    public init(id: ID, title: String, accountTitle: String) {
        self.id = id
        self.title = title
        self.accountTitle = accountTitle
    }
}

public struct ChatIntentAccount: Equatable, Sendable {
    public let id: Int64
    public let title: String

    public init(id: Int64, title: String) {
        self.id = id
        self.title = title
    }
}

public protocol ChatIntentsDataSource: AnyObject, Sendable {
    @MainActor var isLocked: Bool { get }
    func recentChats(limit: Int) async -> [ChatIntentRecord]
    func searchChats(query: String, limit: Int) async -> [ChatIntentRecord]
    func chats(ids: [ChatIntentRecord.ID]) async -> [ChatIntentRecord]
    func allFolders() async -> [ChatIntentFolder]
    func allAccounts() async -> [ChatIntentAccount]
    func openChat(_ id: ChatIntentRecord.ID) async -> Bool
    func sendMessage(_ text: String, to id: ChatIntentRecord.ID) async -> Bool
}

public enum ChatIntentResult: Equatable, Sendable {
    case done
    case locked
    case unavailable
    case emptyText
    case failed
}

public final class ChatIntentsLogic: Sendable {
    public static let suggestedLimit = 20
    public static let searchLimit = 30

    private let source: @Sendable () -> ChatIntentsDataSource?

    public init(source: @escaping @Sendable () -> ChatIntentsDataSource?) {
        self.source = source
    }

    private func unlockedSource() async -> ChatIntentsDataSource? {
        guard let source = self.source() else {
            return nil
        }
        if await source.isLocked {
            return nil
        }
        return source
    }

    public func suggested() async -> [ChatIntentRecord] {
        return await self.unlockedSource()?.recentChats(limit: ChatIntentsLogic.suggestedLimit) ?? []
    }

    public func search(_ query: String) async -> [ChatIntentRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return await self.suggested()
        }
        return await self.unlockedSource()?.searchChats(query: query, limit: ChatIntentsLogic.searchLimit) ?? []
    }

    public func chats(ids: [ChatIntentRecord.ID]) async -> [ChatIntentRecord] {
        guard !ids.isEmpty else {
            return []
        }
        return await self.unlockedSource()?.chats(ids: ids) ?? []
    }

    public func folders() async -> [ChatIntentFolder] {
        return await self.unlockedSource()?.allFolders() ?? []
    }

    public func accounts() async -> [ChatIntentAccount] {
        return await self.unlockedSource()?.allAccounts() ?? []
    }

    private func check() async -> (ChatIntentsDataSource?, ChatIntentResult?) {
        guard let source = self.source() else {
            return (nil, .unavailable)
        }
        if await source.isLocked {
            return (nil, .locked)
        }
        return (source, nil)
    }

    public func open(_ id: ChatIntentRecord.ID) async -> ChatIntentResult {
        let (source, failure) = await self.check()
        guard let source = source else {
            return failure ?? .unavailable
        }
        return await source.openChat(id) ? .done : .failed
    }

    public func send(_ text: String, to id: ChatIntentRecord.ID) async -> ChatIntentResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .emptyText
        }
        let (source, failure) = await self.check()
        guard let source = source else {
            return failure ?? .unavailable
        }
        return await source.sendMessage(text, to: id) ? .done : .failed
    }
}

public enum ChatIntentsBridge {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentSource: ChatIntentsDataSource?

    public static var dataSource: ChatIntentsDataSource? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return currentSource
        }
        set {
            lock.lock()
            currentSource = newValue
            lock.unlock()
        }
    }

    public static let logic = ChatIntentsLogic(source: { ChatIntentsBridge.dataSource })
}

public struct ChatFocusFilter: Codable, Equatable, Sendable {
    public var accountIds: [Int64]
    public var folders: [ChatIntentFolder.ID]

    public init(accountIds: [Int64], folders: [ChatIntentFolder.ID]) {
        self.accountIds = accountIds
        self.folders = folders
    }

    public var isEmpty: Bool {
        return self.accountIds.isEmpty && self.folders.isEmpty
    }
}

public final class ChatFocusFilterStore: @unchecked Sendable {
    public static let shared = ChatFocusFilterStore(defaults: .standard)
    public static let didChangeNotification = Notification.Name("ChatFocusFilterStoreDidChange")
    private static let key = "nanogram.focusFilter"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var value: ChatFocusFilter

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: ChatFocusFilterStore.key), let value = try? JSONDecoder().decode(ChatFocusFilter.self, from: data) {
            self.value = value
        } else {
            self.value = ChatFocusFilter(accountIds: [], folders: [])
        }
    }

    public var current: ChatFocusFilter {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }

    public func update(_ filter: ChatFocusFilter) {
        self.lock.lock()
        self.value = filter
        self.lock.unlock()
        if filter.isEmpty {
            self.defaults.removeObject(forKey: ChatFocusFilterStore.key)
        } else if let data = try? JSONEncoder().encode(filter) {
            self.defaults.set(data, forKey: ChatFocusFilterStore.key)
        }
        NotificationCenter.default.post(name: ChatFocusFilterStore.didChangeNotification, object: self)
    }

    public func needsFolderMembership(accountId: Int64) -> Bool {
        let filter = self.current
        return !filter.accountIds.contains(accountId) && filter.folders.contains(where: { $0.accountId == accountId })
    }

    public func allows(accountId: Int64, peerId: Int64, folderIds: Set<Int32>) -> Bool {
        let filter = self.current
        if filter.isEmpty {
            return true
        }
        if filter.accountIds.contains(accountId) {
            return true
        }
        return filter.folders.contains(where: { $0.accountId == accountId && folderIds.contains($0.folderId) })
    }
}
