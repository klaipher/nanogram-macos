import Foundation

enum ChatListReadiness {
    static func isReady(isLoading: Bool, hasContent: Bool) -> Bool {
        return hasContent || !isLoading
    }

    static let fallbackDelay: TimeInterval = 1.0
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

struct ChatListRecentViewCache<Key: Equatable, Value> {
    private(set) var entries: [(key: Key, value: Value)] = []
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

    mutating func put(_ key: Key, _ value: Value) {
        entries.removeAll(where: { $0.key == key })
        entries.insert((key, value), at: 0)
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
