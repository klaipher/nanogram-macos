import XCTest
import SwiftSignalKit
import InlineStickerLayer

final class InlineStickerImageQueueTests: XCTestCase {
    func testImageGenerationLeavesMainThread() {
        let expectation = self.expectation(description: "delivered")
        var onMain: Bool?
        let signal: Signal<Int, NoError> = .single(1)
        let disposable = (signal |> deliverOnImageGenerationQueue(synchronous: false)).start(next: { _ in
            onMain = Thread.isMainThread
            expectation.fulfill()
        })
        wait(for: [expectation], timeout: 5)
        disposable.dispose()
        XCTAssertEqual(onMain, false)
    }

    func testSynchronousKeepsCallerThread() {
        var onMain: Bool?
        let signal: Signal<Int, NoError> = .single(1)
        _ = (signal |> deliverOnImageGenerationQueue(synchronous: true)).start(next: { _ in
            onMain = Thread.isMainThread
        })
        XCTAssertEqual(onMain, true)
    }
}
