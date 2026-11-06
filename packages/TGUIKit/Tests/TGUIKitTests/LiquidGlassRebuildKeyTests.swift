import XCTest
import AppKit
@testable import TGUIKit

final class LiquidGlassRebuildKeyTests: XCTestCase {
    func testThemeSwitchRebuildsOnlyGlassAfterTheFirstTheme() {
        let light = LiquidGlassThemeKey(background: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), isDark: false)
        let tinted = LiquidGlassThemeKey(background: NSColor(srgbRed: 0.9, green: 0.8, blue: 0.7, alpha: 1), isDark: false)
        XCTAssertFalse(LiquidGlassThemeSwitch.needsRebuild(previous: nil, current: light, usesGlass: true))
        XCTAssertFalse(LiquidGlassThemeSwitch.needsRebuild(previous: light, current: light, usesGlass: true))
        XCTAssertTrue(LiquidGlassThemeSwitch.needsRebuild(previous: light, current: tinted, usesGlass: true))
        XCTAssertTrue(LiquidGlassThemeSwitch.needsRebuild(previous: light, current: LiquidGlassThemeKey(background: light.background, isDark: true), usesGlass: true))
        XCTAssertFalse(LiquidGlassThemeSwitch.needsRebuild(previous: light, current: tinted, usesGlass: false))
    }

    func testKeyDiffersWhenEffectTypeOrBakedAppearanceDiffers() {
        let base = LiquidGlassRebuildKey(usesGlass: true, blurEnabled: true, forceAppearance: .forceDark)
        XCTAssertNotEqual(base, LiquidGlassRebuildKey(usesGlass: false, blurEnabled: true, forceAppearance: .forceDark))
        XCTAssertNotEqual(base, LiquidGlassRebuildKey(usesGlass: true, blurEnabled: false, forceAppearance: .forceDark))
        XCTAssertNotEqual(base, LiquidGlassRebuildKey(usesGlass: true, blurEnabled: true, forceAppearance: .forceLight))
    }

    func testTintCacheSkipsEqualColorsAndWritesChangedOnes() {
        var cache = AppliedValueCache<NSColor>()
        XCTAssertTrue(cache.needsWrite(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)))
        XCTAssertFalse(cache.needsWrite(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)))
        XCTAssertTrue(cache.needsWrite(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.5)))
    }

    func testAppearanceCacheSkipsSameAppearanceAndWritesAfterInvalidate() {
        var cache = AppliedValueCache<NSAppearance>()
        let dark = NSAppearance(named: .darkAqua)!
        let light = NSAppearance(named: .aqua)!
        XCTAssertTrue(cache.needsWrite(dark))
        XCTAssertFalse(cache.needsWrite(NSAppearance(named: .darkAqua)!))
        XCTAssertTrue(cache.needsWrite(light))
        cache.invalidate()
        XCTAssertTrue(cache.needsWrite(light))
    }

    func testBorderKeyChangesWithEachInput() {
        var cache = AppliedValueCache<LiquidGlassBorderKey>()
        let base = LiquidGlassBorderKey(usesGlass: false, hasBorder: true, isDark: false, highContrast: false)
        XCTAssertTrue(cache.needsWrite(base))
        XCTAssertFalse(cache.needsWrite(base))
        XCTAssertTrue(cache.needsWrite(LiquidGlassBorderKey(usesGlass: false, hasBorder: true, isDark: true, highContrast: false)))
        XCTAssertTrue(cache.needsWrite(LiquidGlassBorderKey(usesGlass: false, hasBorder: false, isDark: true, highContrast: false)))
        XCTAssertTrue(cache.needsWrite(LiquidGlassBorderKey(usesGlass: true, hasBorder: false, isDark: true, highContrast: false)))
        XCTAssertTrue(cache.needsWrite(LiquidGlassBorderKey(usesGlass: true, hasBorder: false, isDark: true, highContrast: true)))
    }
}
