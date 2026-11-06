import XCTest
import AppKit
@testable import TGUIKit

final class LiquidGlassRebuildKeyTests: XCTestCase {
    func testKeyIgnoresTintSoTintChangesNeverRebuildTheEffectView() {
        let a = LiquidGlassRebuildKey(usesGlass: true, blurEnabled: true, forceAppearance: .forceDark)
        let b = LiquidGlassRebuildKey(usesGlass: true, blurEnabled: true, forceAppearance: .forceDark)
        XCTAssertEqual(a, b)
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
        let base = LiquidGlassBorderKey(usesGlass: false, hasBorder: true, isDark: false)
        XCTAssertTrue(cache.needsWrite(base))
        XCTAssertFalse(cache.needsWrite(base))
        XCTAssertTrue(cache.needsWrite(LiquidGlassBorderKey(usesGlass: false, hasBorder: true, isDark: true)))
        XCTAssertTrue(cache.needsWrite(LiquidGlassBorderKey(usesGlass: false, hasBorder: false, isDark: true)))
        XCTAssertTrue(cache.needsWrite(LiquidGlassBorderKey(usesGlass: true, hasBorder: false, isDark: true)))
    }
}
