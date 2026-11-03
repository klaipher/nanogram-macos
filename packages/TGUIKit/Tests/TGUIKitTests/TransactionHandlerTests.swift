import XCTest
@testable import TGUIKit

final class TransactionHandlerTests: XCTestCase {
    func testExecuteRunsTheHandlerOnceAndClearsIt() {
        let handler = TransactionHandler()
        var runs = 0
        handler.set(handler: { runs += 1 })
        XCTAssertTrue(handler.isExutable)
        XCTAssertTrue(handler.execute())
        XCTAssertFalse(handler.execute())
        XCTAssertEqual(runs, 1)
        XCTAssertFalse(handler.isExutable)
    }

    func testTheHandlerRunsAfterItWasTakenSoItCanScheduleTheNextOne() {
        let handler = TransactionHandler()
        var stillPendingWhileRunning: Bool?
        handler.set(handler: {
            stillPendingWhileRunning = handler.isExutable
            handler.set(handler: {})
        })
        XCTAssertTrue(handler.execute())
        XCTAssertEqual(stillPendingWhileRunning, false)
        XCTAssertTrue(handler.isExutable)
    }
}
