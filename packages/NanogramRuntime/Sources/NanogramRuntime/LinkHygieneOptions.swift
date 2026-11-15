import Foundation
import NanogramDebug
@_exported import NanogramFeatures

// The link-hygiene logic (tracking list, strippingTracking, isTelegramLink) is the iOS core's NanogramFeatures module,
// compiled through packages/NanogramFeatures. Only the Mac's switches and their defaults live here.
extension LinkHygiene {
    public static let stripOptionId = "links.stripTracking"
    public static let confirmOptionId = "links.confirmTelegramLinks"

    public static let stripOption = NanogramDebugOption.toggle(id: stripOptionId, section: "Links", title: "Remove tracking from links", detail: "Opening or copying a link drops tracking parameters such as utm_source, fbclid and gclid. Your messages are never changed.", defaultValue: false).userFacing()

    public static let confirmOption = NanogramDebugOption.toggle(id: confirmOptionId, section: "Links", title: "Ask before opening Telegram links", detail: "Links to t.me and tg:// ask for confirmation first, since they can join a channel or open a bot.", defaultValue: false).userFacing()

    public static func stripsTracking(in settings: NanogramDebugSettings) -> Bool {
        return settings.bool(stripOptionId)
    }

    public static func confirmsTelegramLinks(in settings: NanogramDebugSettings) -> Bool {
        return settings.bool(confirmOptionId)
    }

    public static var stripsTracking: Bool {
        return LinkHygiene.stripsTracking(in: NanogramDebugSettings.shared)
    }

    public static var confirmsTelegramLinks: Bool {
        return LinkHygiene.confirmsTelegramLinks(in: NanogramDebugSettings.shared)
    }

    public static func cleanedIfEnabled(_ link: String) -> String {
        return LinkHygiene.stripsTracking ? LinkHygiene.strippingTracking(link) : link
    }
}
