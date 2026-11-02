import AppKit

// Upstream's MainMenu.xib files (one per localization) name the app "Telegram". Rather than editing all of
// them, the app menu and main window are renamed at launch: only items where "Telegram" is the app name
// change; Telegram features such as "Telegram Premium" keep their names.
public enum Branding {
    public static let appName = "Nanogram"
    static let upstreamName = "Telegram"

    // The xib menu items are MMMenuItem (Telegram-Mac/app/MMMenuItem.swift): their title getter returns the
    // language pack's "<identifier>.title", which may put the app name anywhere ("Telegram beenden").
    // These identifiers are About, Hide and Quit in MainMenu.xib; such an item is replaced by a plain item with
    // the rebranded title (clearing the identifier is not enough: AppKit then reports the action's name).
    static let appNameItemIdentifiers: Set<String> = ["5kV-Vb-QxS", "Cag-YX-WT6", "4sb-4s-VLi"]

    static func rebranded(_ title: String) -> String {
        if title == upstreamName {
            return appName
        }
        let suffix = " " + upstreamName
        guard title.hasSuffix(suffix) else {
            return title
        }
        return String(title.dropLast(upstreamName.count)) + appName
    }

    static func replacingAppName(in title: String) -> String {
        title.replacingOccurrences(of: "\\b\(upstreamName)\\b", with: appName, options: .regularExpression)
    }

    @MainActor
    static func plainCopy(of item: NSMenuItem, title: String) -> NSMenuItem {
        let copy = NSMenuItem(title: title, action: item.action, keyEquivalent: item.keyEquivalent)
        copy.keyEquivalentModifierMask = item.keyEquivalentModifierMask
        copy.target = item.target
        copy.tag = item.tag
        copy.state = item.state
        copy.isEnabled = item.isEnabled
        copy.isHidden = item.isHidden
        copy.isAlternate = item.isAlternate
        copy.indentationLevel = item.indentationLevel
        copy.toolTip = item.toolTip
        copy.image = item.image
        copy.representedObject = item.representedObject
        let submenu = item.submenu
        item.submenu = nil
        copy.submenu = submenu
        return copy
    }

    @MainActor
    public static func apply(to menu: NSMenu) {
        if menu.identifier == nil {
            menu.title = rebranded(menu.title)
        }
        for (index, item) in menu.items.enumerated() {
            if let identifier = item.identifier?.rawValue {
                if appNameItemIdentifiers.contains(identifier) {
                    menu.removeItem(at: index)
                    menu.insertItem(plainCopy(of: item, title: replacingAppName(in: item.title)), at: index)
                }
            } else {
                item.title = rebranded(item.title)
            }
            if let submenu = menu.items[index].submenu {
                apply(to: submenu)
            }
        }
    }

    // MainMenu.xib also titles the main window "Telegram" (shown before an account is connected).
    @MainActor
    public static func apply(to windows: [NSWindow]) {
        for window in windows where window.title == upstreamName {
            window.title = appName
        }
    }

    // The main menu and window are loaded from MainMenu.xib by NSApplicationMain, after the hooks are installed.
    static func installMenuHook() {
        NotificationCenter.default.addObserver(forName: NSApplication.willFinishLaunchingNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let menu = NSApplication.shared.mainMenu {
                    apply(to: menu)
                }
                apply(to: NSApplication.shared.windows)
            }
        }
    }
}
