import Foundation
import Intents
import UserNotifications

public struct CommunicationNotificationInfo {
    public static let conversationKey = "intent.conversation.id"
    public static let threadKey = "intent.thread.id"
    public static let senderIdKey = "intent.sender.id"
    public static let senderNameKey = "intent.sender.name"
    public static let groupNameKey = "intent.group.name"
    public static let mutedKey = "intent.muted"
    public static let accountKey = "intent.account.id"

    public let conversationId: Int64
    public let threadId: Int64?
    public let senderId: Int64
    public let senderName: String
    public let groupName: String?
    public let isMuted: Bool
    public let accountId: Int64
    public let avatarPNG: Data?

    public init?(userInfo: [AnyHashable: Any], avatarPNG: Data?) {
        guard let conversationId = userInfo[CommunicationNotificationInfo.conversationKey] as? Int64, let senderId = userInfo[CommunicationNotificationInfo.senderIdKey] as? Int64, let senderName = userInfo[CommunicationNotificationInfo.senderNameKey] as? String, let accountId = userInfo[CommunicationNotificationInfo.accountKey] as? Int64 else {
            return nil
        }
        self.conversationId = conversationId
        self.threadId = userInfo[CommunicationNotificationInfo.threadKey] as? Int64
        self.senderId = senderId
        self.senderName = senderName
        self.groupName = userInfo[CommunicationNotificationInfo.groupNameKey] as? String
        self.isMuted = userInfo[CommunicationNotificationInfo.mutedKey] as? Bool ?? false
        self.accountId = accountId
        self.avatarPNG = avatarPNG
    }

    public var conversationIdentifier: String {
        return "tg\(self.conversationId)"
    }

    public var threadIdentifier: String {
        if let threadId = self.threadId {
            return "\(self.conversationIdentifier)_\(threadId)"
        }
        return self.conversationIdentifier
    }

    public var donationGroupIdentifier: String {
        return CommunicationNotifications.donationGroupIdentifier(accountId: self.accountId)
    }
}

public enum CommunicationNotifications {
    public static func donationGroupIdentifier(accountId: Int64) -> String {
        return "account.\(accountId)"
    }

    @available(macOS 12.0, *)
    public static func makeIntent(_ info: CommunicationNotificationInfo) -> INSendMessageIntent {
        let handle = INPersonHandle(value: "tg\(info.senderId)", type: .unknown)
        let image = info.avatarPNG.map { INImage(imageData: $0) }
        let sender = INPerson(personHandle: handle, nameComponents: nil, displayName: info.senderName, image: image, contactIdentifier: nil, customIdentifier: "tg\(info.senderId)")
        let groupName = info.groupName.map { INSpeakableString(spokenPhrase: $0) }
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: nil, speakableGroupName: groupName, conversationIdentifier: info.conversationIdentifier, serviceName: nil, sender: sender, attachments: nil)
        return intent
    }

    @available(macOS 12.0, *)
    public static func apply(_ info: CommunicationNotificationInfo, to content: UNMutableNotificationContent, donate: (INInteraction) -> Void = { $0.donate(completion: nil) }, update: (UNMutableNotificationContent, INSendMessageIntent) throws -> UNNotificationContent = { try $0.updating(from: $1) }) -> UNNotificationContent {
        content.threadIdentifier = info.threadIdentifier
        content.interruptionLevel = info.isMuted ? .passive : .active
        let intent = makeIntent(info)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.groupIdentifier = info.donationGroupIdentifier
        donate(interaction)
        do {
            return try update(content, intent)
        } catch {
            return content
        }
    }

    public static func deleteDonations(accountId: Int64) {
        INInteraction.delete(with: donationGroupIdentifier(accountId: accountId), completion: nil)
    }
}

public enum NotificationAvatarStore {
    public static var directory: URL {
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nanogram-notification-avatars", isDirectory: true)
    }

    public static func write(_ png: Data, identifier: String) -> URL? {
        let directory = self.directory
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let name = String(identifier.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let url = directory.appendingPathComponent(name.isEmpty ? "avatar" : name).appendingPathExtension("png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
