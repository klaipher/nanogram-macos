import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

/// The wait for a reaction effect file. It only decides how long the animation waits for the file;
/// the download itself is owned by `ReactionEffectFetches` and is never cancelled when the wait ends.
enum ReactionEffectFileWait {
    static let limit: Double = 1.5

    static func data(resource: Signal<MediaResourceData, NoError>, limit: Double = ReactionEffectFileWait.limit, queue: Queue = Queue.mainQueue()) -> Signal<MediaResourceData?, NoError> {
        let arrived: Signal<MediaResourceData?, NoError> = resource
        |> filter { $0.complete }
        |> take(1)
        |> map { Optional($0) }
        |> then(.single(nil))

        return arrived
        |> timeout(limit, queue: queue, alternate: .single(nil))
        |> take(1)
    }
}

/// Process-wide downloads of reaction effect files. A download outlives the 1.5 s wait, so on a slow link
/// the file keeps arriving and the effect plays on a later tap. One download per file, capped at `cap` seconds.
final class ReactionEffectFetches {
    static let cap: Double = 30.0
    static let shared = ReactionEffectFetches()

    private let lock = NSLock()
    private var active: [MediaId: MetaDisposable] = [:]

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return active.count
    }

    func isActive(_ id: MediaId) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active[id] != nil
    }

    @discardableResult
    func ensure(_ id: MediaId, fetch: Signal<Void, NoError>, cap: Double = ReactionEffectFetches.cap, queue: Queue = Queue.concurrentDefaultQueue()) -> Bool {
        let meta = MetaDisposable()
        lock.lock()
        if active[id] != nil {
            lock.unlock()
            return false
        }
        active[id] = meta
        lock.unlock()

        let finish: () -> Void = { [weak self, weak meta] in
            guard let self, let meta else {
                return
            }
            self.lock.lock()
            if self.active[id] === meta {
                self.active[id] = nil
            }
            self.lock.unlock()
        }
        meta.set((fetch |> timeout(cap, queue: queue, alternate: .complete())).start(completed: {
            finish()
        }))
        return true
    }
}

enum ReactionEffectPrefetch {
    static let reactionLimit = 8
    /// The first reactions also get the files that are only used on demand (large-reaction effect, builtin activate animation).
    static let onDemandReactionLimit = 4

    static func files(from reactions: [AvailableReactions.Reaction], includePremium: Bool, limit: Int = ReactionEffectPrefetch.reactionLimit) -> [TelegramMediaFile] {
        var files: [TelegramMediaFile] = []
        for (index, reaction) in reactions.filter({ $0.isEnabled && (includePremium || !$0.isPremium) }).prefix(limit).enumerated() {
            if let around = reaction.aroundAnimation {
                files.append(around._parse())
            }
            if let center = reaction.centerAnimation {
                files.append(center._parse())
            }
            if index < onDemandReactionLimit {
                files.append(reaction.effectAnimation._parse())
                files.append(reaction.activateAnimation._parse())
            }
        }
        return files
    }
}
