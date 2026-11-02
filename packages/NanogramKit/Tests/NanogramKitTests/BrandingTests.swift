import AppKit
import XCTest
@testable import NanogramKit

// Stand-in for upstream's MMMenuItem: the title getter returns the language pack's "<identifier>.title" (the
// key itself when missing), so a title set on it is ignored. Like AppKit with nib items, a cleared identifier
// falls back to the action's name.
private final class LanguagePackMenuItem: NSMenuItem {
    nonisolated(unsafe) static var strings = ["4sb-4s-VLi.title": "Telegram beenden", "1Xt-HY-uBw.title": "TelegramMac"]

    override var identifier: NSUserInterfaceItemIdentifier? {
        get { super.identifier ?? action.map { NSUserInterfaceItemIdentifier(NSStringFromSelector($0)) } }
        set { super.identifier = newValue }
    }

    override var title: String {
        get { identifier.map { Self.strings["\($0.rawValue).title"] ?? "\($0.rawValue).title" } ?? super.title }
        set { super.title = newValue }
    }
}

@MainActor
final class BrandingTests: XCTestCase {
    private func mainMenu() -> NSMenu {
        let appMenu = NSMenu(title: "Telegram")
        for title in ["About Telegram", "Telegram Premium", "Hide Telegram", "Hide Others", "Quit Telegram"] {
            appMenu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        let help = NSMenu(title: "Help")
        help.addItem(NSMenuItem(title: "Telegram FAQ", action: nil, keyEquivalent: ""))
        let menu = NSMenu(title: "TelegramMac")
        for (title, submenu) in [("Telegram", appMenu), ("Help", help)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    func test_menu_titles_rebranded() {
        let menu = mainMenu()
        Branding.apply(to: menu)
        let appMenu = menu.items[0]
        XCTAssertEqual(appMenu.title, "Nanogram")
        XCTAssertEqual(appMenu.submenu?.title, "Nanogram")
        XCTAssertEqual(appMenu.submenu?.items.map(\.title),
                       ["About Nanogram", "Telegram Premium", "Hide Nanogram", "Hide Others", "Quit Nanogram"])
        XCTAssertEqual(menu.items[1].submenu?.items.map(\.title), ["Telegram FAQ"])
    }

    func test_rebranding_is_idempotent() {
        let menu = mainMenu()
        Branding.apply(to: menu)
        Branding.apply(to: menu)
        XCTAssertEqual(menu.items[0].submenu?.items.last?.title, "Quit Nanogram")
    }

    func test_language_pack_items_rebranded_by_xib_identifier() {
        let quit = LanguagePackMenuItem(title: "Quit Telegram", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.identifier = NSUserInterfaceItemIdentifier("4sb-4s-VLi")
        quit.keyEquivalentModifierMask = [.command]
        quit.tag = 7
        let other = LanguagePackMenuItem(title: "TelegramMac", action: nil, keyEquivalent: "")
        other.identifier = NSUserInterfaceItemIdentifier("1Xt-HY-uBw")
        let menu = NSMenu(title: "")
        menu.addItem(quit)
        menu.addItem(other)
        Branding.apply(to: menu)
        let rebranded = menu.items[0]
        XCTAssertEqual(rebranded.title, "Nanogram beenden")
        XCTAssertEqual(rebranded.action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(rebranded.keyEquivalent, "q")
        XCTAssertEqual(rebranded.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(rebranded.tag, 7)
        XCTAssertEqual(menu.items.count, 2)
        XCTAssertTrue(menu.items[1] === other)
        XCTAssertEqual(other.title, "TelegramMac")
        XCTAssertEqual(other.identifier?.rawValue, "1Xt-HY-uBw")
    }

    func test_window_titled_with_the_app_name_rebranded() {
        let main = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        main.title = "Telegram"
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        other.title = "Telegram Premium"
        Branding.apply(to: [main, other])
        XCTAssertEqual(main.title, "Nanogram")
        XCTAssertEqual(other.title, "Telegram Premium")
    }

    func test_only_the_app_name_word_is_replaced() {
        XCTAssertEqual(Branding.rebranded("Quit Telegram"), "Quit Nanogram")
        XCTAssertEqual(Branding.rebranded("Telegram"), "Nanogram")
        XCTAssertEqual(Branding.rebranded("Telegram Premium"), "Telegram Premium")
        XCTAssertEqual(Branding.rebranded("Quit TelegramX"), "Quit TelegramX")
    }
}
