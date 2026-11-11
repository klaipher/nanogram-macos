import Foundation
import Postbox
import TelegramCore

public enum MessageWidgetsSwitch {
    public static let defaultsKey = "nanogram.messageWidgets.enabled.2"
    public static let didChangeNotification = Notification.Name("NanogramMessageWidgetsSwitchDidChange")

    public static var isEnabled: Bool {
        return isEnabled(in: .standard)
    }

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        return defaults.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ enabled: Bool) {
        setEnabled(enabled, in: .standard)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

public enum MessageWidgetRowKind: Equatable {
    case widget
    case localBubble
    case botDocument
    case upstream
}

public enum MessageWidgetPolicy {
    public static func rowKind(hasWidgetMedia: Bool, hasLocalBubbleAttribute: Bool, hasBotDocument: Bool, enabled: Bool) -> MessageWidgetRowKind {
        guard enabled else {
            return .upstream
        }
        if hasWidgetMedia {
            return .widget
        }
        if hasLocalBubbleAttribute {
            return .localBubble
        }
        if hasBotDocument {
            return .botDocument
        }
        return .upstream
    }

    public static func allowsDemoEntry(enabled: Bool, serverAllowsDemo: Bool) -> Bool {
        return enabled && serverAllowsDemo
    }

    public static func engineServiceName(embedded: String?, fallback: String) -> String {
        guard let embedded, !embedded.isEmpty else {
            return fallback
        }
        return embedded
    }

    public static func isWidgetCandidate(_ message: Message?) -> Bool {
        guard let message else {
            return false
        }
        return message.media.contains(where: { $0 is TelegramMediaWidget }) || message.htmlBubbleState != nil || HTMLDocumentBubbles.document(in: message) != nil
    }

    public static let engineServiceFallbackName = "org.klaipher.Nanogram.WidgetEngine"
}
