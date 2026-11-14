import XCTest
import Postbox
import SwiftSignalKit
@testable import TelegramMediaUtils

final class CoalescedProgressTests: XCTestCase {
    private func coalescer() -> ProgressCoalescer<MediaResourceStatus> {
        return ProgressCoalescer(minDelta: 0.01, minInterval: 0.1, classify: ProgressSample.of(_:))
    }

    private func emitted(_ decision: ProgressCoalescer<MediaResourceStatus>.Decision) -> MediaResourceStatus? {
        if case let .emit(value) = decision {
            return value
        }
        return nil
    }

    func testFirstProgressIsEmittedImmediately() {
        var c = coalescer()
        XCTAssertEqual(emitted(c.accept(.Fetching(isActive: true, progress: 0.1), now: 0)), .Fetching(isActive: true, progress: 0.1))
    }

    func testFastProgressIsHeldAndTheLatestValueIsFlushed() {
        var c = coalescer()
        _ = c.accept(.Fetching(isActive: true, progress: 0.1), now: 0)
        XCTAssertNil(emitted(c.accept(.Fetching(isActive: true, progress: 0.2), now: 0.01)))
        XCTAssertNil(emitted(c.accept(.Fetching(isActive: true, progress: 0.3), now: 0.02)))
        XCTAssertEqual(c.flush(now: 0.1), .Fetching(isActive: true, progress: 0.3))
        XCTAssertNil(c.flush(now: 0.2))
    }

    func testProgressAfterTheIntervalIsEmitted() {
        var c = coalescer()
        _ = c.accept(.Fetching(isActive: true, progress: 0.1), now: 0)
        XCTAssertEqual(emitted(c.accept(.Fetching(isActive: true, progress: 0.2), now: 0.11)), .Fetching(isActive: true, progress: 0.2))
    }

    func testTinyDeltaIsHeldEvenAfterTheInterval() {
        var c = coalescer()
        _ = c.accept(.Fetching(isActive: true, progress: 0.100), now: 0)
        XCTAssertNil(emitted(c.accept(.Fetching(isActive: true, progress: 0.105), now: 0.5)))
    }

    func testStateChangesAreNeverDelayedAndDropPendingProgress() {
        var c = coalescer()
        _ = c.accept(.Fetching(isActive: true, progress: 0.1), now: 0)
        _ = c.accept(.Fetching(isActive: true, progress: 0.2), now: 0.01)
        XCTAssertEqual(emitted(c.accept(.Local, now: 0.02)), .Local)
        XCTAssertNil(c.flush(now: 0.3))
        XCTAssertEqual(emitted(c.accept(.Paused(progress: 0.2), now: 0.03)), .Paused(progress: 0.2))
    }

    func testActiveToInactiveSwitchIsImmediate() {
        var c = coalescer()
        _ = c.accept(.Fetching(isActive: true, progress: 0.1), now: 0)
        XCTAssertEqual(emitted(c.accept(.Fetching(isActive: false, progress: 0.1), now: 0.001)), .Fetching(isActive: false, progress: 0.1))
    }

    func testCompletionProgressIsNeverHeld() {
        var c = coalescer()
        _ = c.accept(.Fetching(isActive: true, progress: 0.9), now: 0)
        XCTAssertEqual(emitted(c.accept(.Fetching(isActive: true, progress: 1.0), now: 0.001)), .Fetching(isActive: true, progress: 1.0))
    }

    func testRemoteZeroProgressIsAStateChange() {
        var c = coalescer()
        XCTAssertEqual(emitted(c.accept(.Remote(progress: 0), now: 0)), .Remote(progress: 0))
    }

    func testSignalDeliversFirstValueAndTheLastHeldValueBeforeCompletion() {
        let values = Atomic<[Float]>(value: [])
        let done = expectation(description: "completed")
        let signal = Signal<Float?, NoError> { subscriber in
            subscriber.putNext(0.1)
            subscriber.putNext(0.2)
            subscriber.putNext(0.3)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        let disposable = signal.coalescedProgress(classify: ProgressSample.of(updating:)).start(next: { value in
            if let value = value {
                _ = values.modify { $0 + [value] }
            }
        }, completed: {
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        disposable.dispose()
        XCTAssertEqual(values.with { $0 }, [0.1, 0.3])
    }

    func testSignalFlushesHeldValueOnTimer() {
        let values = Atomic<[Float]>(value: [])
        let flushed = expectation(description: "flushed")
        let signal = Signal<Float?, NoError> { subscriber in
            subscriber.putNext(0.1)
            subscriber.putNext(0.5)
            return EmptyDisposable
        }
        let disposable = signal.coalescedProgress(minInterval: 0.05, classify: ProgressSample.of(updating:)).start(next: { value in
            if let value = value {
                let count = values.modify { $0 + [value] }.count
                if count == 2 {
                    flushed.fulfill()
                }
            }
        })
        wait(for: [flushed], timeout: 2)
        disposable.dispose()
        XCTAssertEqual(values.with { $0 }, [0.1, 0.5])
    }
}
