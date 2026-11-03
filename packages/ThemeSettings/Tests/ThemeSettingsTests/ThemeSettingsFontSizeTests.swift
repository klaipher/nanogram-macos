import XCTest
import Postbox
@testable import ThemeSettings

final class ThemeSettingsFontSizeTests: XCTestCase {
    private let sliderSizes: [CGFloat] = [11, 12, 13, 14, 15, 16, 17, 18]

    func testDefaultFontSizeIsFifthSliderStop() {
        XCTAssertEqual(ThemePaletteSettings.defaultFontSize, 15)
        XCTAssertEqual(sliderSizes.firstIndex(of: ThemePaletteSettings.defaultFontSize), 4)
    }

    func testDefaultThemeUsesDefaultFontSize() {
        XCTAssertEqual(ThemePaletteSettings.defaultTheme.fontSize, ThemePaletteSettings.defaultFontSize)
    }

    func testStoredFontSizeIsKept() throws {
        let stored = ThemePaletteSettings.defaultTheme.withUpdatedFontSize(13)
        let decoded = try XCTUnwrap(PreferencesEntry(stored)?.get(ThemePaletteSettings.self))
        XCTAssertEqual(decoded.fontSize, 13)
    }

    func testMissingFontSizeDecodesToDefault() throws {
        let data = try JSONEncoder().encode(ThemePaletteSettings.defaultTheme.withUpdatedFontSize(17))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "fontSize"))
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ThemePaletteSettings.self, from: stripped)
        XCTAssertEqual(decoded.fontSize, ThemePaletteSettings.defaultFontSize)
    }
}
