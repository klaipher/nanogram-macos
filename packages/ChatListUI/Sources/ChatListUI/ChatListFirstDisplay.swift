import Foundation
import Postbox

enum ChatListReadiness {
    static func isReady(isLoading: Bool, hasContent: Bool) -> Bool {
        return hasContent || !isLoading
    }

    static let defaultFallbackDelay: TimeInterval = 1.0
    static let forumFallbackDelay: TimeInterval = 0.35

    static func fallbackDelay(mode: PeerListMode) -> TimeInterval {
        switch mode {
        case .forum, .savedMessagesChats:
            return forumFallbackDelay
        default:
            return defaultFallbackDelay
        }
    }
}

enum ChatListFirstDisplayPolicy {
    static func waitsForBanners(mode: PeerListMode) -> Bool {
        switch mode {
        case .plain:
            return true
        default:
            return false
        }
    }
}

enum ChatListPendingPushPolicy {
    static func cancels(pendingMode: PeerListMode, newLocationPeerId: PeerId?, folderChanged: Bool) -> Bool {
        let pendingPeerId: PeerId
        switch pendingMode {
        case let .forum(peerId, _, _):
            pendingPeerId = peerId
        case let .savedMessagesChats(peerId):
            pendingPeerId = peerId
        default:
            return false
        }
        if folderChanged {
            return true
        }
        guard let newLocationPeerId else {
            return false
        }
        return newLocationPeerId != pendingPeerId
    }
}

enum ChatListCachedReplay {
    static let delay: Double = 0.1
    static let maxAge: Double = 30.0

    static func usesCache(isInitialRequest: Bool, hasScrollPosition: Bool) -> Bool {
        return isInitialRequest && !hasScrollPosition
    }
}

struct ChatListCachedReplayGate {
    private(set) var liveEmitted = false
    private(set) var cachedEmitted = false

    mutating func liveArrived() {
        liveEmitted = true
    }

    mutating func shouldEmitCached() -> Bool {
        if liveEmitted || cachedEmitted {
            return false
        }
        cachedEmitted = true
        return true
    }
}

struct ChatListRecentViewCache<Key: Equatable, Value> {
    private(set) var entries: [(key: Key, value: Value, time: Double)] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func get(_ key: Key) -> Value? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else {
            return nil
        }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: 0)
        return entry.value
    }

    func peek(_ key: Key) -> Value? {
        return entries.first(where: { $0.key == key })?.value
    }

    func fresh(_ key: Key, now: Double, maxAge: Double) -> Value? {
        guard let entry = entries.first(where: { $0.key == key }) else {
            return nil
        }
        if now - entry.time > maxAge {
            return nil
        }
        return entry.value
    }

    mutating func put(_ key: Key, _ value: Value, at time: Double = 0) {
        entries.removeAll(where: { $0.key == key })
        entries.insert((key, value, time), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    mutating func remove(_ key: Key) {
        entries.removeAll(where: { $0.key == key })
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    var count: Int {
        return entries.count
    }
}
