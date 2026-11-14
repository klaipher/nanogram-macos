import XCTest
import SwiftSignalKit
@testable import ChatExportUI

final class ExportBlockingTests: XCTestCase {
    func testReturnsSynchronousValue() {
        let signal = Signal<Int, NoError> { subscriber in
            subscriber.putNext(7)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        XCTAssertEqual(ExportBlocking.first(signal, timeout: 5, isCancelled: { false }), 7)
    }

    func testReturnsValueDeliveredFromAnotherQueue() {
        let signal = Signal<Int, NoError> { subscriber in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                subscriber.putNext(42)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
        XCTAssertEqual(ExportBlocking.first(signal, timeout: 5, isCancelled: { false }), 42)
    }

    func testCompletionWithoutValueReturnsNil() {
        let signal = Signal<Int, NoError> { subscriber in
            subscriber.putCompletion()
            return EmptyDisposable
        }
        XCTAssertNil(ExportBlocking.first(signal, timeout: 5, isCancelled: { false }))
    }

    func testTimeoutDisposesAndReturnsNil() {
        let disposed = Atomic<Bool>(value: false)
        let signal = Signal<Int, NoError> { _ in
            return ActionDisposable { _ = disposed.swap(true) }
        }
        let started = Date()
        XCTAssertNil(ExportBlocking.first(signal, timeout: 0.3, pollInterval: 0.05, isCancelled: { false }))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(disposed.with { $0 })
    }

    func testCancellationDisposesAndReturnsNil() {
        let disposed = Atomic<Bool>(value: false)
        let signal = Signal<Int, NoError> { _ in
            return ActionDisposable { _ = disposed.swap(true) }
        }
        XCTAssertNil(ExportBlocking.first(signal, timeout: 0, pollInterval: 0.05, isCancelled: { true }))
        XCTAssertTrue(disposed.with { $0 })
    }

    func testTickRunsWhileWaiting() {
        let ticks = Atomic<Int>(value: 0)
        let signal = Signal<Int, NoError> { subscriber in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                subscriber.putNext(1)
            }
            return EmptyDisposable
        }
        XCTAssertEqual(ExportBlocking.first(signal, timeout: 5, pollInterval: 0.05, isCancelled: { false }, onTick: { _ = ticks.modify { $0 + 1 } }), 1)
        XCTAssertGreaterThan(ticks.with { $0 }, 0)
    }

    func testLateValueAfterTimeoutIsHarmless() {
        let signal = Signal<Int, NoError> { subscriber in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                subscriber.putNext(1)
            }
            return EmptyDisposable
        }
        XCTAssertNil(ExportBlocking.first(signal, timeout: 0.1, pollInterval: 0.02, isCancelled: { false }))
        Thread.sleep(forTimeInterval: 0.5)
    }
}
