import Intents
import UserNotifications
import XCTest
@testable import NanogramRuntime

final class CommunicationNotificationsTests: XCTestCase {
    private func userInfo(group: String? = "Team", muted: Bool = false, thread: Int64? = nil) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            CommunicationNotificationInfo.conversationKey: Int64(777),
            CommunicationNotificationInfo.senderIdKey: Int64(42),
            CommunicationNotificationInfo.senderNameKey: "Alice",
            CommunicationNotificationInfo.mutedKey: muted,
            CommunicationNotificationInfo.accountKey: Int64(5),
        ]
        if let group = group {
            info[CommunicationNotificationInfo.groupNameKey] = group
        }
        if let thread = thread {
            info[CommunicationNotificationInfo.threadKey] = thread
        }
        return info
    }

    func testParsesUserInfoAndBuildsThreadIdentifiers() {
        let info = CommunicationNotificationInfo(userInfo: userInfo(thread: 3), avatarPNG: nil)
        XCTAssertEqual(info?.conversationIdentifier, "tg777")
        XCTAssertEqual(info?.threadIdentifier, "tg777_3")
        XCTAssertEqual(CommunicationNotificationInfo(userInfo: userInfo(), avatarPNG: nil)?.threadIdentifier, "tg777")
        XCTAssertNil(CommunicationNotificationInfo(userInfo: [:], avatarPNG: nil))
    }

    @available(macOS 12.0, *)
    func testIntentCarriesSenderConversationAndGroupName() throws {
        let info = try XCTUnwrap(CommunicationNotificationInfo(userInfo: userInfo(), avatarPNG: Data([1, 2, 3])))
        let intent = CommunicationNotifications.makeIntent(info)
        XCTAssertEqual(intent.conversationIdentifier, "tg777")
        XCTAssertEqual(intent.sender?.customIdentifier, "tg42")
        XCTAssertEqual(intent.sender?.displayName, "Alice")
        XCTAssertNotNil(intent.sender?.image)
        XCTAssertEqual(intent.speakableGroupName?.spokenPhrase, "Team")
        let direct = CommunicationNotifications.makeIntent(try XCTUnwrap(CommunicationNotificationInfo(userInfo: userInfo(group: nil), avatarPNG: nil)))
        XCTAssertNil(direct.speakableGroupName)
    }

    @available(macOS 12.0, *)
    func testFallsBackToPlainContentWhenUpdatingFails() throws {
        struct Failure: Error {}
        let content = UNMutableNotificationContent()
        content.title = "Plain"
        let info = try XCTUnwrap(CommunicationNotificationInfo(userInfo: userInfo(muted: true), avatarPNG: nil))
        let result = CommunicationNotifications.apply(info, to: content, donate: { _ in }, update: { _, _ in throw Failure() })
        XCTAssertEqual(result.title, "Plain")
        XCTAssertEqual(result.threadIdentifier, "tg777")
        XCTAssertEqual(result.interruptionLevel, .passive)
    }

    @available(macOS 12.0, *)
    func testUsesUpdatedContentAndDonatesOnce() throws {
        let content = UNMutableNotificationContent()
        let updated = UNMutableNotificationContent()
        updated.title = "Updated"
        var donations = 0
        let info = try XCTUnwrap(CommunicationNotificationInfo(userInfo: userInfo(), avatarPNG: nil))
        let result = CommunicationNotifications.apply(info, to: content, donate: { _ in donations += 1 }, update: { _, _ in updated })
        XCTAssertEqual(result.title, "Updated")
        XCTAssertEqual(donations, 1)
        XCTAssertEqual(content.interruptionLevel, .active)
    }

    func testAvatarFileIsAPngInOneReusedDirectory() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let first = try XCTUnwrap(NotificationAvatarStore.write(png, identifier: "msg_1"))
        let second = try XCTUnwrap(NotificationAvatarStore.write(png, identifier: "msg_2"))
        XCTAssertEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        XCTAssertEqual(first.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: first), png)
    }
}
