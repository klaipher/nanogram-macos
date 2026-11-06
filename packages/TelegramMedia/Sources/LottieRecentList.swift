import Foundation

struct LottieRecentList<Key: Hashable, Value> {
    let capacity: Int
    private var order: [Key] = []
    private var values: [Key: Value] = [:]

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int {
        return self.order.count
    }

    func contains(_ key: Key) -> Bool {
        return self.values[key] != nil
    }

    mutating func use(_ key: Key, _ value: Value) -> [Value] {
        if self.values[key] != nil, let index = self.order.firstIndex(of: key) {
            self.order.remove(at: index)
        }
        self.order.append(key)
        self.values[key] = value
        var evicted: [Value] = []
        while self.order.count > self.capacity {
            let oldest = self.order.removeFirst()
            if let value = self.values.removeValue(forKey: oldest) {
                evicted.append(value)
            }
        }
        return evicted
    }

    mutating func removeAll() -> [Value] {
        let all = self.order.compactMap { self.values[$0] }
        self.order = []
        self.values = [:]
        return all
    }
}
