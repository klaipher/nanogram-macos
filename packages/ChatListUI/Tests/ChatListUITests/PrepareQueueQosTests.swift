import XCTest
import Foundation
import SwiftSignalKit
import TelegramTheme

final class PrepareQueueQosTests: XCTestCase {
    private func qos(of queue: Queue) -> qos_class_t {
        let expectation = expectation(description: "queue ran")
        var qos = QOS_CLASS_UNSPECIFIED
        queue.async {
            qos = qos_class_self()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        return qos
    }

    func testChatListPrepareQueueRunsAtUserInitiated() {
        XCTAssertEqual(qos(of: chatListPrepareQueue), QOS_CLASS_USER_INITIATED)
    }

    func testSharedPrepareQueueStaysAtUtility() {
        XCTAssertEqual(qos(of: prepareQueue), QOS_CLASS_UTILITY)
    }
}
