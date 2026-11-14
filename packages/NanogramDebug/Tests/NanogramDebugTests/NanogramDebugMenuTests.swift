import AppKit
import XCTest
@testable import NanogramDebug
@testable import NanogramDebugUI

final class NanogramDebugMenuTests: XCTestCase {
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu(title: "Main")
        let appItem = NSMenuItem(title: "Nanogram", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Nanogram")
        appMenu.addItem(NSMenuItem(title: "About Nanogram", action: nil, keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Nanogram", action: nil, keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        return main
    }

    private func makeSettings() -> (NanogramDebugSettings, String) {
        let suite = "NanogramDebugMenuTests.\(UUID().uuidString)"
        let settings = NanogramDebugSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.register(.toggle(id: "video.hardware", section: "Video", title: "Hardware decoding", defaultValue: true))
        settings.register(.choice(id: "display.cap", section: "Display", title: "Frame-rate cap", options: [.init(id: "off", title: "Off"), .init(id: "60", title: "60 Hz")], defaultValue: "off"))
        return (settings, suite)
    }

    func testInstallAddsOneItemAfterSettings() {
        let main = makeMainMenu()
        let menu = NanogramDebugMenu(settings: makeSettings().0, openDeveloperScreen: { false })
        menu.install(in: main)
        menu.install(in: main)
        let titles = main.items[0].submenu!.items.map { $0.title }
        XCTAssertEqual(titles, ["About Nanogram", "Settings…", "Debug Settings…", "", "Quit Nanogram"])
    }

    func testOpensDeveloperScreenWhenAvailable() {
        let main = makeMainMenu()
        var asked = 0
        let menu = NanogramDebugMenu(settings: makeSettings().0, openDeveloperScreen: {
            asked += 1
            return true
        })
        menu.install(in: main)
        menu.open()
        XCTAssertEqual(asked, 1)
    }

    func testFootnoteJoinsDetailAndRelaunchNote() {
        XCTAssertNil(NanogramDebugOption.toggle(id: "a", section: "S", title: "A", defaultValue: false).footnote)
        XCTAssertEqual(NanogramDebugOption.toggle(id: "a", section: "S", title: "A", detail: "Detail.", requiresRelaunch: true, defaultValue: false).footnote, "Detail. Applies after relaunch.")
        XCTAssertEqual(NanogramDebugOption.toggle(id: "a", section: "S", title: "A", requiresRelaunch: true, defaultValue: false).footnote, "Applies after relaunch.")
    }

    func testSectionsKeepRegistrationOrderForTheInlinePage() {
        let (settings, _) = makeSettings()
        XCTAssertEqual(settings.sections.map { $0.title }, ["Video", "Display"])
        XCTAssertEqual(settings.sections.flatMap { $0.options.map { $0.id } }, ["video.hardware", "display.cap"])
    }
}
