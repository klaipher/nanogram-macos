import Foundation
import UserNotifications

public protocol DeliveredNotificationCenter: AnyObject {
    func deliveredNotificationInfos(_ completion: @escaping ([(identifier: String, userInfo: [AnyHashable: Any])]) -> Void)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@available(macOS 10.14, *)
extension UNUserNotificationCenter: DeliveredNotificationCenter {
    public func deliveredNotificationInfos(_ completion: @escaping ([(identifier: String, userInfo: [AnyHashable: Any])]) -> Void) {
        self.getDeliveredNotifications(completionHandler: { notifications in
            completion(notifications.map { (identifier: $0.request.identifier, userInfo: $0.request.content.userInfo) })
        })
    }
}

public final class DeliveredNotificationClearer<Key: Hashable> {
    private let center: DeliveredNotificationCenter
    private let key: ([AnyHashable: Any]) -> Key?

    public init(center: DeliveredNotificationCenter, key: @escaping ([AnyHashable: Any]) -> Key?) {
        self.center = center
        self.key = key
    }

    public func remove(matching keys: Set<Key>) {
        guard !keys.isEmpty else {
            return
        }
        self.remove(where: { key, _ in
            return keys.contains(key)
        })
    }

    public func remove(where predicate: @escaping (Key, [AnyHashable: Any]) -> Bool) {
        let center = self.center
        let key = self.key
        center.deliveredNotificationInfos({ notifications in
            var identifiers: [String] = []
            for notification in notifications {
                if let value = key(notification.userInfo), predicate(value, notification.userInfo) {
                    identifiers.append(notification.identifier)
                }
            }
            if !identifiers.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        })
    }
}
