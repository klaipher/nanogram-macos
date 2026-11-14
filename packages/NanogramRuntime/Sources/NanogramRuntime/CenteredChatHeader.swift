import Foundation
import NanogramDebug

/// Settings > Nanogram Features > "Centered chat header". Off (the default) keeps the upstream chat header: the title capsule
/// fills the room between the controls and pinned, translate, search and Reopen Topic sit beside it when the window is wide.
/// On centres the title capsule and puts pinned and translate in a bounded capsule under it.
public enum CenteredChatHeader {
    public static let optionId = "chat.centeredHeader"

    public static let debugOption = NanogramDebugOption.toggle(id: optionId, section: "Chat", title: "Centered chat header", detail: "The chat title capsule sits in the middle of the chat, and pinned and translate bars are a centered capsule under it. Off keeps the original Telegram layout. Applies to open chats right away.", defaultValue: false).userFacing("Put the chat title in the middle of the header, with the pinned message and translation bar centered under it. Off keeps Telegram's original layout.")

    public static func isEnabled(in settings: NanogramDebugSettings) -> Bool {
        if settings.isOverridden(optionId) {
            return settings.bool(optionId)
        }
        if case let .toggle(defaultValue) = debugOption.kind {
            return defaultValue
        }
        return false
    }

    public static var isEnabled: Bool {
        return CenteredChatHeader.isEnabled(in: NanogramDebugSettings.shared)
    }

    /// Calls `handler` when the switch changes (on the thread that changed it). Keep the returned object alive; dropping it stops the calls.
    public static func observe(in settings: NanogramDebugSettings = NanogramDebugSettings.shared, _ handler: @escaping () -> Void) -> AnyObject {
        return settings.observe(optionId) { _ in
            handler()
        }
    }
}
