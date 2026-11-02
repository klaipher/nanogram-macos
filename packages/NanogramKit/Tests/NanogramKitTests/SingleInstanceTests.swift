import Foundation
import XCTest
@testable import NanogramKit

final class SingleInstanceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func instance(_ pid: pid_t, launchedAfter seconds: TimeInterval?) -> SingleInstance.Instance {
        SingleInstance.Instance(pid: pid, launchDate: seconds.map { start.addingTimeInterval($0) })
    }

    func test_alone_keepsRunning() {
        XCTAssertNil(SingleInstance.instanceToActivate(current: instance(10, launchedAfter: 5), others: []))
    }

    func test_olderInstanceRunning_currentYieldsToIt() {
        let older = instance(7, launchedAfter: 0)
        XCTAssertEqual(SingleInstance.instanceToActivate(current: instance(10, launchedAfter: 5), others: [older]), older)
    }

    func test_currentIsOldest_keepsRunning() {
        let newer = instance(12, launchedAfter: 9)
        XCTAssertNil(SingleInstance.instanceToActivate(current: instance(10, launchedAfter: 5), others: [newer]))
    }

    func test_simultaneousLaunch_exactlyOneKeepsRunning() {
        let a = instance(10, launchedAfter: 5)
        let b = instance(11, launchedAfter: 5)
        let aYields = SingleInstance.instanceToActivate(current: a, others: [b]) != nil
        let bYields = SingleInstance.instanceToActivate(current: b, others: [a]) != nil
        XCTAssertNotEqual(aYields, bYields)
        XCTAssertFalse(aYields, "the lower pid wins a tie")
    }

    func test_unknownLaunchDate_countsAsNewest() {
        let undated = instance(3, launchedAfter: nil)
        XCTAssertNil(SingleInstance.instanceToActivate(current: instance(10, launchedAfter: 5), others: [undated]))
        XCTAssertEqual(SingleInstance.instanceToActivate(current: undated, others: [instance(10, launchedAfter: 5)]),
                       instance(10, launchedAfter: 5))
    }

    func test_ensure_withNoOtherInstance_returnsTrue() {
        XCTAssertTrue(SingleInstance.ensure(bundleIdentifier: "org.klaipher.Nanogram.tests.not-running"))
    }
}
