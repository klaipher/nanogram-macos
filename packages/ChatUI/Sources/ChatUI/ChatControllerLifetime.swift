import Foundation
import os
import SwiftSignalKit

final class LiveInstanceCounter: @unchecked Sendable {
    struct Snapshot: Equatable {
        let live: Int
        let created: Int
        let deinitialized: Int
        let peak: Int
    }

    private let lock = NSLock()
    private var live = 0
    private var created = 0
    private var deinitialized = 0
    private var peak = 0

    @discardableResult
    func instanceCreated() -> Snapshot {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.live += 1
        self.created += 1
        self.peak = max(self.peak, self.live)
        return Snapshot(live: self.live, created: self.created, deinitialized: self.deinitialized, peak: self.peak)
    }

    @discardableResult
    func instanceDeinitialized() -> Snapshot {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.live = max(0, self.live - 1)
        self.deinitialized += 1
        return Snapshot(live: self.live, created: self.created, deinitialized: self.deinitialized, peak: self.peak)
    }

    var snapshot: Snapshot {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return Snapshot(live: self.live, created: self.created, deinitialized: self.deinitialized, peak: self.peak)
    }
}

enum ChatControllerLifetime {
    static let counter = LiveInstanceCounter()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Telegram", category: "ChatControllerLifetime")

    static func created() {
        let snapshot = counter.instanceCreated()
        NanogramSignposts.event(PerformanceSignpostName.chatControllerCreated)
        logger.info("chat controller created live=\(snapshot.live, privacy: .public) created=\(snapshot.created, privacy: .public) deinit=\(snapshot.deinitialized, privacy: .public) peak=\(snapshot.peak, privacy: .public)")
    }

    static func deinitialized() {
        let snapshot = counter.instanceDeinitialized()
        NanogramSignposts.event(PerformanceSignpostName.chatControllerDeinit)
        logger.info("chat controller deinit live=\(snapshot.live, privacy: .public) created=\(snapshot.created, privacy: .public) deinit=\(snapshot.deinitialized, privacy: .public) peak=\(snapshot.peak, privacy: .public)")
    }
}
