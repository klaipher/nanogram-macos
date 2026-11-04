import XCTest
import Foundation
import TelegramTheme

final class PrepareQueueQosTests: XCTestCase {
    func testPrepareQueueRunsAtUserInitiated() {
        let expectation = expectation(description: "prepare queue ran")
        var qos = QOS_CLASS_UNSPECIFIED
        prepareQueue.async {
            qos = qos_class_self()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(qos, QOS_CLASS_USER_INITIATED)
    }
}
