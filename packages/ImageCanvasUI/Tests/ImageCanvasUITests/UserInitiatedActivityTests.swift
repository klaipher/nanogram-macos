import XCTest
import SwiftSignalKit
@testable import ImageCanvasUI

final class UserInitiatedActivityTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var begun = 0
        private var ended = 0
        func begin() { lock.lock(); begun += 1; lock.unlock() }
        func end() { lock.lock(); ended += 1; lock.unlock() }
        var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (begun, ended) }
    }

    private func factory(_ counter: Counter) -> (String) -> UserInitiatedActivity {
        return { reason in
            UserInitiatedActivity(reason: reason, begin: { _, _ in counter.begin(); return NSObject() }, end: { _ in counter.end() })
        }
    }

    func testEndsOnceWhenExplicitlyEndedTwice() {
        let counter = Counter()
        let activity = factory(counter)("test")
        activity.end()
        activity.end()
        XCTAssertEqual(counter.counts.0, 1)
        XCTAssertEqual(counter.counts.1, 1)
    }

    func testEndsOnCompletion() {
        let counter = Counter()
        let signal = Signal<Int, NoError> { subscriber in
            subscriber.putNext(1)
            subscriber.putCompletion()
            return EmptyDisposable
        }.holdingUserInitiatedActivity(reason: "test", make: factory(counter))
        let disposable = signal.start(next: { _ in })
        XCTAssertEqual(counter.counts.0, 1)
        XCTAssertEqual(counter.counts.1, 1)
        disposable.dispose()
        XCTAssertEqual(counter.counts.1, 1)
    }

    func testEndsOnDisposeBeforeCompletion() {
        let counter = Counter()
        let signal = Signal<Int, NoError> { _ in EmptyDisposable }
            .holdingUserInitiatedActivity(reason: "test", make: factory(counter))
        let disposable = signal.start(next: { _ in })
        XCTAssertEqual(counter.counts.1, 0)
        disposable.dispose()
        XCTAssertEqual(counter.counts.0, 1)
        XCTAssertEqual(counter.counts.1, 1)
    }

    func testEndsOnError() {
        let counter = Counter()
        let signal = Signal<Int, String> { subscriber in
            subscriber.putError("x")
            return EmptyDisposable
        }.holdingUserInitiatedActivity(reason: "test", make: factory(counter))
        _ = signal.start(next: { _ in }, error: { _ in })
        XCTAssertEqual(counter.counts.1, 1)
    }
}
