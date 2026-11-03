import Foundation
import XCTest
@testable import NanogramRuntime

final class DatabaseMaintenanceGateTests: XCTestCase {
    func testVacuumOnlyAfterTenMinutesWithoutInput() {
        XCTAssertFalse(DatabaseMaintenanceGate.allowsVacuum(userIdle: 0))
        XCTAssertFalse(DatabaseMaintenanceGate.allowsVacuum(userIdle: 599))
        XCTAssertTrue(DatabaseMaintenanceGate.allowsVacuum(userIdle: 600))
    }

    func testTheSizeCapIsOneGigabyteOfLiveData() {
        XCTAssertEqual(DatabaseMaintenanceGate.maximumLiveBytes, 1024 * 1024 * 1024)
    }
}
