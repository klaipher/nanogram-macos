import XCTest
import SwiftSignalKit
@testable import ChatUI

final class AnimatedEmojiSeedTests: XCTestCase {
    private func collect(_ signal: Signal<[String: Int], NoError>, for duration: Double) -> [[String: Int]] {
        let values = Atomic<[[String: Int]]>(value: [])
        let disposable = signal.start(next: { value in
            _ = values.modify { $0 + [value] }
        })
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
        disposable.dispose()
        return values.with { $0 }
    }

    func testAnAlreadyLoadedPackIsDeliveredWithoutAnEmptySeed() {
        let promise = Promise<[String: Int]>(["a": 1])
        let values = collect(AnimatedEmojiSeed.signal(source: promise.get(), delay: 0.2, queue: Queue.mainQueue()), for: 0.05)
        XCTAssertEqual(values, [["a": 1]])
    }

    func testAPackThatArrivesQuicklyReplacesTheEmptySeed() {
        let promise = Promise<[String: Int]>()
        Queue.mainQueue().after(0.05) { promise.set(.single(["a": 1])) }
        let values = collect(AnimatedEmojiSeed.signal(source: promise.get(), delay: 0.3, queue: Queue.mainQueue()), for: 0.15)
        XCTAssertEqual(values, [["a": 1]])
    }

    func testASlowPackFallsBackToEmptyAndThenArrives() {
        let promise = Promise<[String: Int]>()
        Queue.mainQueue().after(0.25) { promise.set(.single(["a": 1])) }
        let values = collect(AnimatedEmojiSeed.signal(source: promise.get(), delay: 0.05, queue: Queue.mainQueue()), for: 0.4)
        XCTAssertEqual(values, [[:], ["a": 1]])
    }
}
