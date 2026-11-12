import XCTest
import TelegramCore
import TelegramUtils

final class PresenceRefreshTimeoutTests: XCTestCase {
    private func timeout(_ presence: TelegramUserPresence, at timestamp: Int32) -> Double {
        return peerPresenceStatusRefreshTimeout(presence, timeDifference: 0, relativeTo: Double(timestamp), mode: .statusText)
    }

    func testExpiringOnlineStatusWaitsForTheNextLabel() {
        let presence = TelegramUserPresence(status: .present(until: 1_800_000_000), lastActivity: 0)
        XCTAssertEqual(timeout(presence, at: 1_800_000_000), 59.0)
    }

    func testFutureOnlineStatusKeepsItsDeadline() {
        let presence = TelegramUserPresence(status: .present(until: 1_800_000_060), lastActivity: 0)
        XCTAssertEqual(timeout(presence, at: 1_800_000_000), 60.0)
    }

    func testExpiredStatusHasPositiveTimeout() {
        let presence = TelegramUserPresence(status: .present(until: 1_800_000_000), lastActivity: 0)
        for elapsed in 1 ... 3600 {
            XCTAssertGreaterThan(timeout(presence, at: 1_800_000_000 + Int32(elapsed)), 0)
        }
    }

    func testPermanentOnlineStatusDoesNotCreateTimer() {
        let presence = TelegramUserPresence(status: .present(until: Int32.max), lastActivity: 0)
        XCTAssertEqual(timeout(presence, at: 1_800_000_000), .infinity)
    }
}
