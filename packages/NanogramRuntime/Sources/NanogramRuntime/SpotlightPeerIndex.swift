import CoreSpotlight
import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public protocol SpotlightIndexing: AnyObject {
    func indexSearchableItems(_ items: [CSSearchableItem], completionHandler: (@Sendable (Error?) -> Void)?)
    func deleteSearchableItems(withIdentifiers identifiers: [String], completionHandler: (@Sendable (Error?) -> Void)?)
    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String], completionHandler: (@Sendable (Error?) -> Void)?)
    func deleteAllSearchableItems(completionHandler: (@Sendable (Error?) -> Void)?)
}

extension CSSearchableIndex: SpotlightIndexing {
}

public struct SpotlightPeerEntry: Equatable {
    public let peerId: Int64
    public let uniqueIdentifier: String
    public let title: String
    public let accountTitle: String
    public let avatarPNG: Data?

    public init(peerId: Int64, uniqueIdentifier: String, title: String, accountTitle: String, avatarPNG: Data?) {
        self.peerId = peerId
        self.uniqueIdentifier = uniqueIdentifier
        self.title = title
        self.accountTitle = accountTitle
        self.avatarPNG = avatarPNG
    }

    public static func sameIndexContent(_ lhs: [SpotlightPeerEntry], _ rhs: [SpotlightPeerEntry]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        for (left, right) in zip(lhs, rhs) {
            if left.peerId != right.peerId || left.title != right.title || left.accountTitle != right.accountTitle {
                return false
            }
        }
        return true
    }
}

public final class SpotlightPeerIndex {
    public static let itemLifetime: TimeInterval = 30 * 24 * 60 * 60

    private static var didResetThisLaunch = false

    private let index: SpotlightIndexing
    private let domain: String
    private var indexed: [SpotlightPeerEntry] = []
    private var latest: [SpotlightPeerEntry] = []
    private var isLocked = false

    public init(index: SpotlightIndexing = CSSearchableIndex.default(), accountId: Int64) {
        self.index = index
        self.domain = SpotlightPeerIndex.domain(accountId: accountId)
    }

    public static func domain(accountId: Int64) -> String {
        return "account.\(accountId)"
    }

    public static func removeItemsFromEarlierLaunches(_ index: SpotlightIndexing = CSSearchableIndex.default()) {
        if didResetThisLaunch {
            return
        }
        didResetThisLaunch = true
        index.deleteAllSearchableItems(completionHandler: nil)
    }

    static func resetLaunchState() {
        didResetThisLaunch = false
    }

    public func update(_ entries: [SpotlightPeerEntry]) {
        self.latest = entries
        if self.isLocked {
            return
        }
        self.apply(entries)
    }

    public func setLocked(_ locked: Bool) {
        guard locked != self.isLocked else {
            return
        }
        self.isLocked = locked
        if locked {
            self.removeIndexed()
        } else {
            self.apply(self.latest)
        }
    }

    public func removeAll() {
        self.latest = []
        self.removeIndexed()
    }

    private func removeIndexed() {
        self.indexed = []
        self.index.deleteSearchableItems(withDomainIdentifiers: [self.domain], completionHandler: nil)
    }

    private func apply(_ entries: [SpotlightPeerEntry]) {
        if SpotlightPeerEntry.sameIndexContent(self.indexed, entries), self.indexed.map({ $0.avatarPNG }) == entries.map({ $0.avatarPNG }) {
            return
        }
        let current = Set(entries.map { $0.uniqueIdentifier })
        let removed = self.indexed.map { $0.uniqueIdentifier }.filter { !current.contains($0) }
        if !removed.isEmpty {
            self.index.deleteSearchableItems(withIdentifiers: removed, completionHandler: nil)
        }
        let previous = Dictionary(self.indexed.map { ($0.uniqueIdentifier, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        let changed = entries.filter { previous[$0.uniqueIdentifier] != $0 }
        if !changed.isEmpty {
            self.index.indexSearchableItems(changed.map { self.makeItem($0) }, completionHandler: nil)
        }
        self.indexed = entries
    }

    func makeItem(_ entry: SpotlightPeerEntry) -> CSSearchableItem {
        let attributes: CSSearchableItemAttributeSet
        if #available(macOS 11.0, *) {
            attributes = CSSearchableItemAttributeSet(contentType: UTType.contact)
        } else {
            attributes = CSSearchableItemAttributeSet(itemContentType: "public.contact")
        }
        attributes.title = entry.title
        attributes.displayName = entry.title
        attributes.contentDescription = entry.accountTitle
        attributes.thumbnailData = entry.avatarPNG
        attributes.kind = "Contact"
        let item = CSSearchableItem(uniqueIdentifier: entry.uniqueIdentifier, domainIdentifier: self.domain, attributeSet: attributes)
        item.expirationDate = Date(timeIntervalSinceNow: SpotlightPeerIndex.itemLifetime)
        return item
    }
}
