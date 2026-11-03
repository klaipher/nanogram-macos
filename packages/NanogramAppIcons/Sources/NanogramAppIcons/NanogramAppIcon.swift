import AppKit

public struct NanogramAppIcon: Hashable, Sendable {
    public let name: String
    public let title: String

    public static let all: [NanogramAppIcon] = [
        NanogramAppIcon(name: "NanogramComet", title: "Comet"),
        NanogramAppIcon(name: "NanogramWhite", title: "White"),
        NanogramAppIcon(name: "NanogramGlass", title: "Glass"),
        NanogramAppIcon(name: "NanogramOrbit", title: "Orbit"),
        NanogramAppIcon(name: "NanogramBubble", title: "Bubble"),
        NanogramAppIcon(name: "NanogramSpeed", title: "Speed"),
        NanogramAppIcon(name: "NanogramSplitN", title: "Split N"),
        NanogramAppIcon(name: "NanogramRibbon", title: "Ribbon"),
        NanogramAppIcon(name: "NanogramDot", title: "N-dot"),
        NanogramAppIcon(name: "NanogramNight", title: "Night"),
        NanogramAppIcon(name: "NanogramClassic", title: "Classic"),
        NanogramAppIcon(name: "NanogramDash", title: "Dash"),
        NanogramAppIcon(name: "NanogramForward", title: "Forward"),
        NanogramAppIcon(name: "NanogramStreak", title: "Streak"),
    ]

    public static var defaultIcon: NanogramAppIcon {
        return all[0]
    }

    public var isDefault: Bool {
        return self == NanogramAppIcon.defaultIcon
    }

    public var storedName: String? {
        return isDefault ? nil : name
    }

    public static func selected(storedName: String?) -> NanogramAppIcon {
        return all.first(where: { $0.name == storedName }) ?? defaultIcon
    }

    public static func migratedStoredName(_ storedName: String?) -> String? {
        return selected(storedName: storedName).storedName
    }

    public var url: URL? {
        return Bundle.module.url(forResource: name, withExtension: "icns", subdirectory: "Icons")
    }

    public func image() -> NSImage? {
        guard let url = url, let image = NSImage(contentsOf: url), image.isValid else {
            return nil
        }
        return image
    }
}
