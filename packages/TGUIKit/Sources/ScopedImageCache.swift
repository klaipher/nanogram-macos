import Cocoa
import CoreMedia
import os

public final class ImageDisplayScope {
    public let id: Int

    fileprivate init(id: Int) {
        self.id = id
    }

    deinit {
        ScopedImageCache.scopeClosed(id)
    }
}

public struct ScopedImageCacheStatistics: Equatable {
    public var hits: Int = 0
    public var misses: Int = 0
    public var collisions: Int = 0
    public var stores: Int = 0
    public var evictions: Int = 0
    public var purged: Int = 0

    public init() {
    }

    public func summary(name: String, entries: Int, bytes: Int) -> String {
        return "\(name): hits=\(hits) misses=\(misses) collisions=\(collisions) stores=\(stores) evictions=\(evictions) purged=\(purged) entries=\(entries) bytes=\(bytes)"
    }
}

private let imageCacheLog = OSLog(subsystem: "org.telegram.TGUIKit", category: .pointsOfInterest)

public final class ScopedImageCache {
    private struct Entry {
        let image: CGImage
        let identity: AnyHashable?
        let sampleBuffer: CMSampleBuffer?
        let cost: Int
        var lastUsed: CFAbsoluteTime
        var scopes: Set<Int>
        var orphanedAt: CFAbsoluteTime?
    }

    private final class WeakCache {
        weak var value: ScopedImageCache?
        init(_ value: ScopedImageCache) {
            self.value = value
        }
    }

    public let name: String
    public let countLimit: Int
    public let byteLimit: Int
    public let idleTimeout: TimeInterval
    public let closedScopeGrace: TimeInterval
    private let sweepInterval: TimeInterval
    private let clock: () -> CFAbsoluteTime

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var keysByImage: [ObjectIdentifier: [Int]] = [:]
    private var keysByScope: [Int: Set<Int>] = [:]
    private var totalCost: Int = 0
    private var counters = ScopedImageCacheStatistics()
    private var lastReported = ScopedImageCacheStatistics()
    private var sweepTimer: DispatchSourceTimer?
    private let sweepQueue = DispatchQueue(label: "org.telegram.scopedImageCache.sweep", qos: .utility)

    public init(name: String = "image", countLimit: Int, byteLimit: Int, idleTimeout: TimeInterval, closedScopeGrace: TimeInterval, sweepInterval: TimeInterval = 60, clock: @escaping () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent) {
        self.name = name
        self.countLimit = countLimit
        self.byteLimit = byteLimit
        self.idleTimeout = idleTimeout
        self.closedScopeGrace = closedScopeGrace
        self.sweepInterval = sweepInterval
        self.clock = clock
        ScopedImageCache.register(self)
    }

    deinit {
        sweepTimer?.cancel()
    }

    public func setImage(_ image: CGImage, sampleBuffer: CMSampleBuffer?, forKey key: Int, identity: AnyHashable? = nil) {
        let cost = image.bytesPerRow * image.height
        var released: [Entry] = []

        lock.lock()
        if let previous = removeEntry(key) {
            released.append(previous)
        }
        counters.stores += 1
        entries[key] = Entry(image: image, identity: identity, sampleBuffer: sampleBuffer, cost: cost, lastUsed: clock(), scopes: [], orphanedAt: nil)
        keysByImage[ObjectIdentifier(image), default: []].append(key)
        totalCost += cost
        let evicted = evictIfNeeded()
        counters.evictions += evicted.count
        released.append(contentsOf: evicted)
        startSweepTimerIfNeeded()
        lock.unlock()

        if !evicted.isEmpty {
            os_signpost(.event, log: imageCacheLog, name: "ImageCache evict", "%{public}s evicted %d", name, evicted.count)
        }

        released.removeAll()
    }

    public func image(forKey key: Int, identity: AnyHashable? = nil) -> (CGImage, CMSampleBuffer?)? {
        lock.lock()
        let result: (CGImage, CMSampleBuffer?)?
        var collided = false
        if let entry = entries[key] {
            if let identity = identity, let stored = entry.identity, stored != identity {
                counters.misses += 1
                counters.collisions += 1
                collided = true
                result = nil
            } else {
                entries[key]?.lastUsed = clock()
                counters.hits += 1
                result = (entry.image, entry.sampleBuffer)
            }
        } else {
            counters.misses += 1
            result = nil
        }
        lock.unlock()

        if collided {
            os_signpost(.event, log: imageCacheLog, name: "ImageCache collision", "%{public}s", name)
        } else if result != nil {
            os_signpost(.event, log: imageCacheLog, name: "ImageCache hit", "%{public}s", name)
        } else {
            os_signpost(.event, log: imageCacheLog, name: "ImageCache miss", "%{public}s", name)
        }
        return result
    }

    public var statistics: ScopedImageCacheStatistics {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    public func removeImage(forKey key: Int) {
        lock.lock()
        let removed = removeEntry(key)
        if entries.isEmpty {
            stopSweepTimer()
        }
        lock.unlock()
        _ = removed
    }

    public func removeAll() {
        lock.lock()
        let removed = entries
        counters.purged += removed.count
        entries.removeAll()
        keysByImage.removeAll()
        keysByScope.removeAll()
        totalCost = 0
        stopSweepTimer()
        lock.unlock()
        _ = removed
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var cost: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalCost
    }

    var isSweeping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sweepTimer != nil
    }

    func sweep() {
        let now = clock()
        var released: [Entry] = []

        lock.lock()
        let expired = entries.compactMap { key, entry -> Int? in
            if now - entry.lastUsed >= idleTimeout {
                return key
            }
            if let orphanedAt = entry.orphanedAt, now - orphanedAt >= closedScopeGrace {
                return key
            }
            return nil
        }
        for key in expired {
            if let entry = removeEntry(key) {
                released.append(entry)
            }
        }
        counters.evictions += released.count
        if entries.isEmpty {
            stopSweepTimer()
        }
        let report: String? = counters == lastReported ? nil : counters.summary(name: name, entries: entries.count, bytes: totalCost)
        lastReported = counters
        lock.unlock()

        if let report = report {
            os_log("%{public}@", log: imageCacheLog, type: .info, report)
        }

        released.removeAll()
    }

    private func contains(_ image: CGImage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keysByImage[ObjectIdentifier(image)] != nil
    }

    private func attach(_ image: CGImage, to scope: Int) {
        lock.lock()
        if let keys = keysByImage[ObjectIdentifier(image)] {
            let now = clock()
            for key in keys where entries[key] != nil {
                entries[key]?.lastUsed = now
                entries[key]?.orphanedAt = nil
                if entries[key]?.scopes.insert(scope).inserted == true {
                    keysByScope[scope, default: []].insert(key)
                }
            }
        }
        lock.unlock()
    }

    private func closeScope(_ scope: Int) {
        var released: [Entry] = []
        var orphaned = false

        lock.lock()
        if let keys = keysByScope.removeValue(forKey: scope) {
            let now = clock()
            for key in keys {
                guard entries[key]?.scopes.remove(scope) != nil, entries[key]?.scopes.isEmpty == true else {
                    continue
                }
                if closedScopeGrace <= 0 {
                    if let entry = removeEntry(key) {
                        released.append(entry)
                        counters.evictions += 1
                    }
                } else {
                    entries[key]?.orphanedAt = now
                    orphaned = true
                }
            }
        }
        if entries.isEmpty {
            stopSweepTimer()
        }
        lock.unlock()

        if orphaned {
            sweepQueue.asyncAfter(deadline: .now() + closedScopeGrace) { [weak self] in
                self?.sweep()
            }
        }
        released.removeAll()
    }

    private func removeEntry(_ key: Int) -> Entry? {
        guard let entry = entries.removeValue(forKey: key) else {
            return nil
        }
        totalCost -= entry.cost
        let imageId = ObjectIdentifier(entry.image)
        if var keys = keysByImage[imageId] {
            keys.removeAll(where: { $0 == key })
            keysByImage[imageId] = keys.isEmpty ? nil : keys
        }
        for scope in entry.scopes {
            keysByScope[scope]?.remove(key)
            if keysByScope[scope]?.isEmpty == true {
                keysByScope.removeValue(forKey: scope)
            }
        }
        return entry
    }

    private func evictIfNeeded() -> [Entry] {
        guard entries.count > countLimit || totalCost > byteLimit else {
            return []
        }
        let evictsFirst: ((key: Int, value: Entry), (key: Int, value: Entry)) -> Bool = { lhs, rhs in
            let lhsOrphaned = lhs.value.orphanedAt != nil
            let rhsOrphaned = rhs.value.orphanedAt != nil
            if lhsOrphaned != rhsOrphaned {
                return lhsOrphaned
            }
            return lhs.value.lastUsed < rhs.value.lastUsed
        }
        var released: [Entry] = []
        if let first = entries.min(by: evictsFirst), let entry = removeEntry(first.key) {
            released.append(entry)
        }
        guard entries.count > countLimit || totalCost > byteLimit else {
            return released
        }
        for (key, _) in entries.sorted(by: evictsFirst) {
            if entries.count <= countLimit && totalCost <= byteLimit {
                break
            }
            if let entry = removeEntry(key) {
                released.append(entry)
            }
        }
        return released
    }

    private func startSweepTimerIfNeeded() {
        guard !entries.isEmpty else {
            stopSweepTimer()
            return
        }
        guard sweepTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: sweepQueue)
        timer.schedule(deadline: .now() + sweepInterval, repeating: sweepInterval, leeway: .milliseconds(Int(sweepInterval * 100)))
        timer.setEventHandler { [weak self] in
            self?.sweep()
        }
        timer.resume()
        sweepTimer = timer
    }

    private func stopSweepTimer() {
        sweepTimer?.cancel()
        sweepTimer = nil
    }
}

extension ScopedImageCache {
    private static let registryLock = NSLock()
    private static var registry: [WeakCache] = []
    private static var nextScopeId: Int = 0
    private static var scopeKey: UInt8 = 0

    public static func diagnosticsSummary() -> String {
        return liveCaches.map { cache in
            cache.statistics.summary(name: cache.name, entries: cache.count, bytes: cache.cost)
        }.joined(separator: "; ")
    }

    private static func register(_ cache: ScopedImageCache) {
        registryLock.lock()
        registry.removeAll(where: { $0.value == nil })
        registry.append(WeakCache(cache))
        registryLock.unlock()
    }

    private static var liveCaches: [ScopedImageCache] {
        registryLock.lock()
        defer { registryLock.unlock() }
        return registry.compactMap { $0.value }
    }

    public static func noteDisplayed(_ image: CGImage, in view: NSView) {
        let holders = liveCaches.filter { $0.contains(image) }
        guard !holders.isEmpty, let scope = displayScope(for: view) else {
            return
        }
        for cache in holders {
            cache.attach(image, to: scope.id)
        }
    }

    static func displayScope(for view: NSView) -> ImageDisplayScope? {
        guard let window = view.window else {
            return nil
        }
        var anchor: AnyObject = window
        var current: NSView? = view
        while let candidate = current {
            if candidate is NSScrollView {
                anchor = candidate
            }
            current = candidate.superview
        }
        if let scope = objc_getAssociatedObject(anchor, &scopeKey) as? ImageDisplayScope {
            return scope
        }
        registryLock.lock()
        nextScopeId += 1
        let scope = ImageDisplayScope(id: nextScopeId)
        registryLock.unlock()
        objc_setAssociatedObject(anchor, &scopeKey, scope, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return scope
    }

    fileprivate static func scopeClosed(_ scope: Int) {
        for cache in liveCaches {
            cache.closeScope(scope)
        }
    }
}
