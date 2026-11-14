import AppKit
import XCTest
@testable import NanogramDebug
@testable import NanogramDebugUI
import NanogramLogExport

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
        XCTAssertNil(menu.windowController)
    }

    func testShowsOwnWindowWithoutLogin() {
        let menu = NanogramDebugMenu(settings: makeSettings().0, openDeveloperScreen: { false })
        menu.open()
        XCTAssertNotNil(menu.windowController)
        menu.windowController?.close()
    }

    func testWindowControlsWriteSettings() {
        let (settings, _) = makeSettings()
        let controller = NanogramDebugWindowController(settings: settings)
        let toggle = controller.control(for: "video.hardware") as? NSButton
        XCTAssertEqual(toggle?.state, .on)
        toggle?.state = .off
        toggle?.performClick(nil)
        XCTAssertEqual(settings.bool("video.hardware"), toggle?.state == .on)
        let popup = controller.control(for: "display.cap") as? NSPopUpButton
        XCTAssertEqual(popup?.indexOfSelectedItem, 0)
        popup?.selectItem(at: 1)
        popup?.sendAction(popup?.action, to: popup?.target)
        XCTAssertEqual(settings.choice("display.cap"), "60")
        settings.set("display.cap", choice: "off")
        XCTAssertEqual(popup?.indexOfSelectedItem, 0)
        controller.close()
    }

    @MainActor
    func testWindowListsEveryLogExport() {
        let controller = NanogramDebugWindowController(settings: makeSettings().0)
        XCTAssertEqual(NanogramLogExportKind.allCases.compactMap { controller.logButton(for: $0)?.title }, ["Send Report…", "Send App Logs…", "Send Call Logs…", "Send Crash Reports…", "Send MetricKit Reports…"])
        let gate = NanogramLogExportGate.shared
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(controller.logButton(for: .appLogs)?.isEnabled ?? true)
        gate.end()
        XCTAssertTrue(controller.logButton(for: .appLogs)?.isEnabled ?? false)
        controller.close()
    }
}
