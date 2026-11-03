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
}
