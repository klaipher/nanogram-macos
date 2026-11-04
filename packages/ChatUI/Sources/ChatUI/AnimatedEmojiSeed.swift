import Foundation
import SwiftSignalKit

enum AnimatedEmojiSeed {
    static let delay: Double = 0.15

    /// A promise that already holds the animated-emoji pack emits synchronously, so there is no delay.
    /// While the pack is still loading, the first history transition waits a short moment for it before
    /// falling back to an empty map, so single-emoji messages are not measured as text and re-laid out.
    static func signal<T>(source: Signal<[String: T], NoError>, delay: Double = AnimatedEmojiSeed.delay, queue: Queue = Queue.mainQueue()) -> Signal<[String: T], NoError> {
        return source
        |> timeout(delay, queue: queue, alternate: .single([:]) |> then(source))
    }
}
