import XCTest
@testable import NanogramRuntime

private final class FakeCenter: DeliveredNotificationCenter {
    var delivered: [(identifier: String, userInfo: [AnyHashable: Any])] = []
    var removeCalls: [[String]] = []

    func deliveredNotificationInfos(_ completion: @escaping ([(identifier: String, userInfo: [AnyHashable: Any])]) -> Void) {
        completion(delivered)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removeCalls.append(identifiers)
        delivered.removeAll(where: { identifiers.contains($0.identifier) })
    }
}

final class DeliveredNotificationClearerTests: XCTestCase {
    private func makeCenter() -> FakeCenter {
        let center = FakeCenter()
        center.delivered = (1 ... 6).map { id in
            (identifier: "n\(id)", userInfo: ["message": id, "peer": id <= 3 ? 10 : 20, "timestamp": Int32(1000 + id)])
        }
        center.delivered.append((identifier: "other", userInfo: [:]))
        return center
    }

    private func clearer(_ center: FakeCenter) -> DeliveredNotificationClearer<Int> {
        return DeliveredNotificationClearer(center: center, key: { $0["message"] as? Int })
    }

    func testReadMessagesRemoveTheirDeliveredNotificationsInOneCall() {
        let center = makeCenter()
        clearer(center).remove(matching: [2, 5, 99])
        XCTAssertEqual(center.removeCalls.count, 1)
        XCTAssertEqual(Set(center.removeCalls[0]), ["n2", "n5"])
        XCTAssertEqual(center.delivered.map { $0.identifier }, ["n1", "n3", "n4", "n6", "other"])
    }

    func testNothingMatchingMakesNoRemoveCall() {
        let center = makeCenter()
        clearer(center).remove(matching: [42])
        XCTAssertEqual(center.removeCalls.count, 0)
    }

    func testPredicateRemovalIsBatched() {
        let center = makeCenter()
        clearer(center).remove(where: { _, userInfo in
            return (userInfo["peer"] as? Int) == 10
        })
        XCTAssertEqual(center.removeCalls.count, 1)
        XCTAssertEqual(Set(center.removeCalls[0]), ["n1", "n2", "n3"])
    }
}
