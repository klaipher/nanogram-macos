import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

enum ReactionEffectFileWait {
    static let limit: Double = 1.5

    static func data(resource: Signal<MediaResourceData, NoError>, fetch: Signal<Void, NoError>, limit: Double = ReactionEffectFileWait.limit, queue: Queue = Queue.mainQueue()) -> Signal<MediaResourceData?, NoError> {
        let arrived: Signal<MediaResourceData?, NoError> = resource
        |> filter { $0.complete }
        |> take(1)
        |> map { Optional($0) }
        |> then(.single(nil))

        let requested = Signal<MediaResourceData?, NoError> { subscriber in
            let fetchDisposable = fetch.start()
            let arrivedDisposable = arrived.start(next: { value in
                subscriber.putNext(value)
            }, completed: {
                subscriber.putCompletion()
            })
            return ActionDisposable {
                fetchDisposable.dispose()
                arrivedDisposable.dispose()
            }
        }

        return requested
        |> timeout(limit, queue: queue, alternate: .single(nil))
        |> take(1)
    }
}

enum ReactionEffectPrefetch {
    static let reactionLimit = 8

    static func files(from reactions: [AvailableReactions.Reaction], includePremium: Bool, limit: Int = ReactionEffectPrefetch.reactionLimit) -> [TelegramMediaFile] {
        var files: [TelegramMediaFile] = []
        for reaction in reactions.filter({ $0.isEnabled && (includePremium || !$0.isPremium) }).prefix(limit) {
            if let around = reaction.aroundAnimation {
                files.append(around._parse())
            }
            if let center = reaction.centerAnimation {
                files.append(center._parse())
            }
        }
        return files
    }
}
