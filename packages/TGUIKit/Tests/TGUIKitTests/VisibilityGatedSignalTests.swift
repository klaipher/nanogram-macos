import XCTest
import SwiftSignalKit
@testable import TGUIKit

final class VisibilityGatedSignalTests: XCTestCase {
    func testThePollIsSubscribedOnlyWhileVisibleAndRestartsOnReveal() {
        var subscriptions = 0
        var active = 0
        let poll = Signal<Int, NoError> { subscriber in
            subscriptions += 1
            active += 1
            subscriber.putNext(subscriptions)
            return ActionDisposable {
                active -= 1
            }
        }
        let visible = ValuePromise<Bool>(true, ignoreRepeated: true)
        var values: [Int] = []
        let disposable = whileVisible(poll, visible: visible.get()).start(next: { values.append($0) })
        XCTAssertEqual(active, 1)
        visible.set(false)
        XCTAssertEqual(active, 0)
        visible.set(false)
        XCTAssertEqual(subscriptions, 1)
        visible.set(true)
        XCTAssertEqual(active, 1)
        XCTAssertEqual(subscriptions, 2)
        XCTAssertEqual(values, [1, 2])
        disposable.dispose()
        XCTAssertEqual(active, 0)
    }

    func testAHiddenStartSubscribesNothing() {
        var subscriptions = 0
        let poll = Signal<Void, NoError> { _ in
            subscriptions += 1
            return EmptyDisposable
        }
        let disposable = whileVisible(poll, visible: .single(false)).start()
        XCTAssertEqual(subscriptions, 0)
        disposable.dispose()
    }

    func testAPollerCreatedPerSubscriptionExistsOnlyWhileVisible() {
        final class Poller {
            static var alive = 0
            static var created = 0
            init() {
                Poller.alive += 1
                Poller.created += 1
            }
            deinit {
                Poller.alive -= 1
            }
        }
        let scoped = Signal<Int, NoError> { subscriber in
            let poller = Poller()
            subscriber.putNext(Poller.created)
            return ActionDisposable {
                withExtendedLifetime(poller) {}
            }
        }
        let visible = ValuePromise<Bool>(false, ignoreRepeated: true)
        let disposable = whileVisible(scoped, visible: visible.get()).start()
        XCTAssertEqual(Poller.created, 0)
        visible.set(true)
        XCTAssertEqual(Poller.alive, 1)
        visible.set(false)
        XCTAssertEqual(Poller.alive, 0)
        visible.set(true)
        XCTAssertEqual(Poller.created, 2)
        disposable.dispose()
        XCTAssertEqual(Poller.alive, 0)
    }
}
