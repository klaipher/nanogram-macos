import AppKit
import XCTest
@testable import NanogramAppIcons

final class NanogramAppIconTests: XCTestCase {
    private let iosPickerOrder: [(name: String, title: String)] = [
        ("NanogramSphere", "Sphere"),
        ("NanogramComet", "Comet"),
        ("NanogramWhite", "White"),
        ("NanogramGlass", "Glass"),
        ("NanogramOrbit", "Orbit"),
        ("NanogramBubble", "Bubble"),
        ("NanogramSpeed", "Speed"),
        ("NanogramSplitN", "Split N"),
        ("NanogramRibbon", "Ribbon"),
        ("NanogramDot", "N-dot"),
        ("NanogramNight", "Night"),
        ("NanogramClassic", "Classic"),
        ("NanogramDash", "Dash"),
        ("NanogramForward", "Forward"),
        ("NanogramStreak", "Streak"),
    ]

    func testPickerListsTheIOSIconsInTheIOSOrder() {
        XCTAssertEqual(NanogramAppIcon.all.map(\.name), iosPickerOrder.map(\.name))
        XCTAssertEqual(NanogramAppIcon.all.map(\.title), iosPickerOrder.map(\.title))
    }

    func testTheSphereIsTheDefaultAndIsStoredAsNoCustomIcon() {
        XCTAssertEqual(NanogramAppIcon.defaultIcon.name, "NanogramSphere")
        XCTAssertTrue(NanogramAppIcon.defaultIcon.isDefault)
        XCTAssertNil(NanogramAppIcon.defaultIcon.storedName)
        XCTAssertEqual(NanogramAppIcon.all.filter(\.isDefault).count, 1)
    }

    func testNoStoredIconSelectsTheDefault() {
        XCTAssertEqual(NanogramAppIcon.selected(storedName: nil), NanogramAppIcon.defaultIcon)
    }

    func testAStoredNanogramIconIsKept() {
        let streak = NanogramAppIcon.selected(storedName: "NanogramStreak")
        XCTAssertEqual(streak.name, "NanogramStreak")
        XCTAssertEqual(NanogramAppIcon.migratedStoredName("NanogramStreak"), "NanogramStreak")
    }

    func testAStoredTelegramIconFallsBackToTheDefault() {
        for telegramIcon in ["Default.icns", "Premium_Black.icns", "Turbo.icns", "Blue_Filled.icns", "unknown"] {
            XCTAssertEqual(NanogramAppIcon.selected(storedName: telegramIcon), NanogramAppIcon.defaultIcon, telegramIcon)
            XCTAssertNil(NanogramAppIcon.migratedStoredName(telegramIcon), telegramIcon)
        }
    }

    func testAStoredDefaultNameMigratesToNoCustomIcon() {
        XCTAssertNil(NanogramAppIcon.migratedStoredName("NanogramSphere"))
        XCTAssertEqual(NanogramAppIcon.migratedStoredName("NanogramComet"), "NanogramComet")
        XCTAssertNil(NanogramAppIcon.migratedStoredName(nil))
    }

    func testEveryIconShipsAMacIconUpTo1024Pixels() throws {
        for icon in NanogramAppIcon.all {
            let image = try XCTUnwrap(icon.image(), icon.name)
            let widths = Set(image.representations.map(\.pixelsWide))
            XCTAssertEqual(widths, [16, 32, 64, 128, 256, 512, 1024], icon.name)
        }
    }
}
