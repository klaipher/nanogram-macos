import UserNotifications
import XCTest
@testable import NanogramRuntime

final class IncomingCallNotificationTests: XCTestCase {
    private let info = IncomingCallNotificationInfo(callId: "A-1", accountId: 7, isVideo: true)

    @available(macOS 12.0, *)
    func testContentIsTimeSensitiveWithTheCallCategory() {
        let content = IncomingCallNotification.makeContent(info, title: "Alice", body: "is calling you...")
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(content.relevanceScore, 1.0)
        XCTAssertEqual(content.categoryIdentifier, IncomingCallNotification.categoryIdentifier)
        XCTAssertEqual(content.title, "Alice")
        XCTAssertEqual(content.body, "is calling you...")
        XCTAssertNil(content.sound)
    }

    func testRequestIdentifierIsDerivedFromTheCallId() {
        let request = IncomingCallNotification.makeRequest(info, title: "x", body: "y")
        XCTAssertEqual(request.identifier, "incomingCall.A-1")
        XCTAssertEqual(IncomingCallNotification.removalIdentifiers(callId: "A-1"), ["incomingCall.A-1"])
        XCTAssertNil(request.trigger)
    }

    func testCategoryCarriesAcceptAndDecline() {
        let category = IncomingCallNotification.makeCategory(acceptTitle: "Accept", declineTitle: "Decline")
        XCTAssertEqual(category.identifier, IncomingCallNotification.categoryIdentifier)
        XCTAssertEqual(category.actions.map { $0.identifier }, [IncomingCallNotification.acceptActionIdentifier, IncomingCallNotification.declineActionIdentifier])
        XCTAssertEqual(category.actions.map { $0.title }, ["Accept", "Decline"])
        XCTAssertTrue(category.actions[0].options.contains(.foreground))
    }

    func testUserInfoRoundTripsIntoATarget() {
        let userInfo = IncomingCallNotification.userInfo(info)
        XCTAssertTrue(IncomingCallNotification.isCall(userInfo: userInfo))
        XCTAssertEqual(IncomingCallNotification.target(actionIdentifier: IncomingCallNotification.acceptActionIdentifier, userInfo: userInfo), IncomingCallNotificationTarget(callId: "A-1", accountId: 7, action: .accept))
        XCTAssertEqual(IncomingCallNotification.target(actionIdentifier: IncomingCallNotification.declineActionIdentifier, userInfo: userInfo)?.action, .decline)
        XCTAssertEqual(IncomingCallNotification.target(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: userInfo)?.action, .open)
    }

    func testForeignUserInfoIsNotACall() {
        XCTAssertFalse(IncomingCallNotification.isCall(userInfo: ["reply": "x"]))
        XCTAssertNil(IncomingCallNotification.target(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:]))
    }
}
