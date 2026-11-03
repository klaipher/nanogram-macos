import AppKit
import NanogramDebug

public final class NanogramDebugMenu: NSObject {
    public static let itemTitle = "Debug Settings…"
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("nanogram.debugSettings")

    private static var installed: NanogramDebugMenu?

    private let settings: NanogramDebugSettings
    private let openDeveloperScreen: () -> Bool
    private(set) var windowController: NanogramDebugWindowController?

    public init(settings: NanogramDebugSettings = .shared, openDeveloperScreen: @escaping () -> Bool) {
        self.settings = settings
        self.openDeveloperScreen = openDeveloperScreen
        super.init()
    }

    public static func install(openDeveloperScreen: @escaping () -> Bool) {
        let menu = NanogramDebugMenu(openDeveloperScreen: openDeveloperScreen)
        if let mainMenu = NSApp.mainMenu {
            menu.install(in: mainMenu)
        }
        installed = menu
    }

    public static func showSwitches() {
        if let installed = installed {
            installed.showWindow()
        } else {
            let menu = NanogramDebugMenu(openDeveloperScreen: { false })
            installed = menu
            menu.showWindow()
        }
    }

    public func install(in mainMenu: NSMenu) {
        guard let appMenu = mainMenu.items.first?.submenu else {
            return
        }
        if appMenu.items.contains(where: { $0.identifier == NanogramDebugMenu.itemIdentifier }) {
            return
        }
        let item = NSMenuItem(title: NanogramDebugMenu.itemTitle, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.identifier = NanogramDebugMenu.itemIdentifier
        item.target = self
        let index: Int
        if let settingsIndex = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }) {
            index = settingsIndex + 1
        } else {
            index = min(1, appMenu.items.count)
        }
        appMenu.insertItem(item, at: index)
    }

    @objc private func menuAction(_ sender: Any?) {
        self.open()
    }

    public func open() {
        if NSApp?.currentEvent?.modifierFlags.contains(.option) == true {
            self.showWindow()
            return
        }
        if self.openDeveloperScreen() {
            return
        }
        self.showWindow()
    }

    public func showWindow() {
        let controller: NanogramDebugWindowController
        if let current = self.windowController {
            controller = current
        } else {
            controller = NanogramDebugWindowController(settings: self.settings)
            self.windowController = controller
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
