import XCTest
import AppKit
@testable import TGUIKit

final class LiquidGlassTreeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
        MainActor.assumeIsolated {
            GlassAccessibilityMonitor.shared.force(GlassAccessibilityState(reduceTransparency: false, increaseContrast: false))
        }
    }

    override func tearDown() {
        System.liquidGlass = false
        MainActor.assumeIsolated {
            GlassAccessibilityMonitor.shared.force(nil)
        }
        super.tearDown()
    }

    private func modes() -> [Bool] {
        return System.liquidGlassAvailable ? [false, true] : [false]
    }

    func testGlassHostsItsEffectViewDirectly() {
        for liquidGlass in modes() {
            System.liquidGlass = liquidGlass
            let glass = LiquidGlassView(frame: NSMakeRect(0, 0, 40, 40), cornerRadius: 20)
            XCTAssertEqual(glass.subviews.count, 1, "liquidGlass \(liquidGlass)")
            XCTAssertTrue(glass.subviews.first === glass.effectView)
            XCTAssertNil(glass.appearanceContainer.superview)
            glass.setFrameSize(NSMakeSize(60, 40))
            glass.layout()
            XCTAssertEqual(glass.effectView.frame, NSMakeRect(0, 0, 60, 40))
        }
    }

    func testRebuiltEffectViewStaysBelowContent() {
        for liquidGlass in modes() {
            System.liquidGlass = liquidGlass
            let glass = LiquidGlassView(frame: NSMakeRect(0, 0, 40, 40), cornerRadius: 20, forceAppearance: .forceLight)
            let content = View(frame: NSMakeRect(4, 4, 32, 32))
            glass.addSubview(content)
            let previous = glass.effectView
            glass.forceAppearance = .forceDark
            XCTAssertFalse(previous === glass.effectView, "liquidGlass \(liquidGlass)")
            XCTAssertTrue(glass.subviews.first === glass.effectView, "liquidGlass \(liquidGlass)")
            XCTAssertTrue(glass.subviews.last === content, "liquidGlass \(liquidGlass)")
        }
    }

    func testGhostAddsOnlyItsEffectViewAsSibling() throws {
        guard System.liquidGlassAvailable else {
            throw XCTSkip("liquid glass is not available")
        }
        System.liquidGlass = true
        let container = GlassContainerView(frame: NSMakeRect(0, 0, 200, 40), flipped: true, spacing: 5)
        let glass = LiquidGlassView(frame: NSMakeRect(0, 0, 40, 40), cornerRadius: 20)
        container.addGhost(glass)
        XCTAssertEqual(container.glassContent.subviews.count, 2)
        XCTAssertTrue(container.glassContent.subviews.contains { $0 === glass })
        XCTAssertTrue(container.glassContent.subviews.contains { $0 === glass.effectView })
        XCTAssertNil(glass.appearanceContainer.superview)
        container.setGhostFrame(glass, frame: NSMakeRect(10, 0, 40, 40), transition: .immediate)
        XCTAssertEqual(glass.effectView.frame, NSMakeRect(10, 0, 40, 40))
        container.removeGhost(glass)
        XCTAssertNil(glass.effectView.superview)
        XCTAssertNil(glass.superview)
    }

    func testHiddenGhostStaysHiddenAfterTheEffectViewIsRebuilt() {
        for liquidGlass in modes() {
            System.liquidGlass = liquidGlass
            let container = GlassContainerView(frame: NSMakeRect(0, 0, 200, 40), flipped: true, spacing: 5)
            let glass = LiquidGlassView(frame: NSMakeRect(0, 0, 40, 40), cornerRadius: 20, forceAppearance: .forceLight)
            container.addGhost(glass)
            container.setGhostFrame(glass, frame: NSMakeRect(10, 0, 40, 40), transition: .immediate)
            glass.isHidden = true
            glass.effectView.alphaValue = 0.5
            let previous = glass.effectView
            let frameBeforeRebuild = glass.effectView.frame
            glass.forceAppearance = .forceDark
            XCTAssertFalse(previous === glass.effectView, "liquidGlass \(liquidGlass)")
            XCTAssertTrue(glass.effectView.isHidden, "liquidGlass \(liquidGlass)")
            XCTAssertEqual(glass.effectView.alphaValue, 0.5, "liquidGlass \(liquidGlass)")
            XCTAssertEqual(glass.effectView.frame, frameBeforeRebuild, "liquidGlass \(liquidGlass)")
            XCTAssertEqual(glass.effectView.frame, glass.effectView.superview === glass ? glass.bounds : NSMakeRect(10, 0, 40, 40), "liquidGlass \(liquidGlass)")
        }
    }

    func testReduceTransparencyTogglingKeepsAHiddenGhostHidden() throws {
        guard System.liquidGlassAvailable else {
            throw XCTSkip("liquid glass is not available")
        }
        System.liquidGlass = true
        let container = GlassContainerView(frame: NSMakeRect(0, 0, 200, 40), flipped: true, spacing: 5)
        let glass = LiquidGlassView(frame: NSMakeRect(0, 0, 40, 40), cornerRadius: 20)
        container.addGhost(glass)
        glass.isHidden = true
        let glassView = glass.effectView
        MainActor.assumeIsolated {
            GlassAccessibilityMonitor.shared.force(GlassAccessibilityState(reduceTransparency: true, increaseContrast: false))
        }
        XCTAssertFalse(glassView === glass.effectView)
        XCTAssertTrue(glass.effectView.isHidden)
        MainActor.assumeIsolated {
            GlassAccessibilityMonitor.shared.force(GlassAccessibilityState(reduceTransparency: false, increaseContrast: false))
        }
        XCTAssertTrue(glass.effectView.isHidden)
    }

    func testIncreaseContrastKeepsGlassAndOnlyStrengthensTheFallbackBorder() throws {
        guard System.liquidGlassAvailable else {
            throw XCTSkip("liquid glass is not available")
        }
        System.liquidGlass = true
        let glass = LiquidGlassView(frame: NSMakeRect(0, 0, 40, 40), cornerRadius: 20)
        let before = glass.effectView
        MainActor.assumeIsolated {
            GlassAccessibilityMonitor.shared.force(GlassAccessibilityState(reduceTransparency: false, increaseContrast: true))
        }
        XCTAssertTrue(before === glass.effectView)
        XCTAssertEqual(glass.effectView.layer?.borderWidth, 0)
    }
}
