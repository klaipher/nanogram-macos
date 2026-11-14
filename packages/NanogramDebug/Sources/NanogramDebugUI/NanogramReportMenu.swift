import AppKit
import NanogramLogExport

public final class NanogramReportMenu: NSObject {
    public static let itemTitle = "Send Report…" //TODOLANG
    static let itemIdentifier = NSUserInterfaceItemIdentifier("nanogram.sendReport")

    nonisolated(unsafe) private static var installed: NanogramReportMenu?

    public static func install(in mainMenu: NSMenu) {
        let handler = installed ?? NanogramReportMenu()
        installed = handler
        handler.install(in: mainMenu)
    }

    func install(in mainMenu: NSMenu) {
        let helpMenu: NSMenu
        if let existing = NSApp?.helpMenu ?? mainMenu.items.first(where: { $0.title == "Help" })?.submenu {
            helpMenu = existing
        } else {
            helpMenu = NSMenu(title: "Help") //TODOLANG
            let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "") //TODOLANG
            item.submenu = helpMenu
            mainMenu.addItem(item)
        }
        NSApp?.helpMenu = helpMenu
        if helpMenu.items.contains(where: { $0.identifier == NanogramReportMenu.itemIdentifier }) {
            return
        }
        let item = NSMenuItem(title: NanogramReportMenu.itemTitle, action: #selector(send(_:)), keyEquivalent: "")
        item.identifier = NanogramReportMenu.itemIdentifier
        item.target = self
        if !helpMenu.items.isEmpty {
            helpMenu.addItem(.separator())
        }
        helpMenu.addItem(item)
    }

    @objc private func send(_ sender: Any?) {
        NanogramLogExport.present(kind: .fullReport, window: NSApp.keyWindow ?? NSApp.mainWindow)
    }
}
