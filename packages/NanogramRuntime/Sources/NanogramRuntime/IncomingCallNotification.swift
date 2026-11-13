import Foundation
import UserNotifications

public struct IncomingCallNotificationInfo: Equatable, Sendable {
    public let callId: String
    public let accountId: Int64
    public let isVideo: Bool

    public init(callId: String, accountId: Int64, isVideo: Bool) {
        self.callId = callId
        self.accountId = accountId
        self.isVideo = isVideo
    }
}

public enum IncomingCallNotificationAction: Equatable {
    case open
    case accept
    case decline
}

public struct IncomingCallNotificationTarget: Equatable {
    public let callId: String
    public let accountId: Int64
    public let action: IncomingCallNotificationAction
}

public enum IncomingCallNotification {
    public static let categoryIdentifier = "incomingCall"
    public static let acceptActionIdentifier = "incomingCall.accept"
    public static let declineActionIdentifier = "incomingCall.decline"
    public static let threadIdentifier = "incomingCall"
    public static let callIdKey = "call.id"
    public static let accountKey = "call.account"
    public static let videoKey = "call.video"

    public static func identifier(callId: String) -> String {
        return "incomingCall.\(callId)"
    }

    public static func removalIdentifiers(callId: String) -> [String] {
        return [identifier(callId: callId)]
    }

    public static func userInfo(_ info: IncomingCallNotificationInfo) -> [AnyHashable: Any] {
        return [callIdKey: info.callId, accountKey: info.accountId, videoKey: info.isVideo]
    }

    public static func isCall(userInfo: [AnyHashable: Any]) -> Bool {
        return userInfo[callIdKey] is String
    }

    public static func target(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> IncomingCallNotificationTarget? {
        guard let callId = userInfo[callIdKey] as? String, let accountId = userInfo[accountKey] as? Int64 else {
            return nil
        }
        let action: IncomingCallNotificationAction
        switch actionIdentifier {
        case acceptActionIdentifier:
            action = .accept
        case declineActionIdentifier:
            action = .decline
        default:
            action = .open
        }
        return IncomingCallNotificationTarget(callId: callId, accountId: accountId, action: action)
    }

    public static func makeContent(_ info: IncomingCallNotificationInfo, title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = threadIdentifier
        content.userInfo = userInfo(info)
        content.sound = nil
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }
        return content
    }

    public static func makeRequest(_ info: IncomingCallNotificationInfo, title: String, body: String) -> UNNotificationRequest {
        return UNNotificationRequest(identifier: identifier(callId: info.callId), content: makeContent(info, title: title, body: body), trigger: nil)
    }

    public static func makeCategory(acceptTitle: String, declineTitle: String) -> UNNotificationCategory {
        let accept = UNNotificationAction(identifier: acceptActionIdentifier, title: acceptTitle, options: [.foreground])
        let decline = UNNotificationAction(identifier: declineActionIdentifier, title: declineTitle, options: [.destructive])
        return UNNotificationCategory(identifier: categoryIdentifier, actions: [accept, decline], intentIdentifiers: [], options: [])
    }
}
