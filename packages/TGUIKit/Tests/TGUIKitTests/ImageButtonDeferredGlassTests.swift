import XCTest
import AppKit
@testable import TGUIKit

final class ImageButtonDeferredGlassTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
        GlassChromeReuse.isEnabled = false
    }

    override func tearDown() {
        GlassChromeReuse.isEnabled = false
        super.tearDown()
    }

    private func makeButton() -> ImageButton {
        let button = ImageButton()
        button.set(image: testImage(CGSize(width: 40, height: 40)), for: .Normal)
        _ = button.sizeToFit(.zero, NSMakeSize(40, 40), thatFit: true)
        return button
    }

    private func glassCount(_ button: ImageButton) -> Int {
        return button.subviews.filter { $0 is LiquidGlassView }.count
    }

    func testFlagDefaultsToOff() {
        XCTAssertFalse(GlassChromeReuse.isEnabled)
    }

    func testFlagOffBuildsTheInnerGlassImmediately() {
        let button = makeButton()
        button.setGlassEffect(size: NSMakeSize(40, 40))
        XCTAssertEqual(glassCount(button), 1)
        XCTAssertTrue(button.interactiveGlassView is LiquidGlassView)
        XCTAssertEqual(viewClassNames(button.subviews), ["LiquidGlassView", "ImageView"])
    }

    func testFlagOnHiddenGlassIsNeverBuilt() {
        GlassChromeReuse.isEnabled = true
        let button = makeButton()
        button.setGlassEffect(size: NSMakeSize(40, 40))
        button.setGlassEffectHidden(true)
        button.updateLayout()
        XCTAssertEqual(glassCount(button), 0)
        XCTAssertNil(button.glassViewIfCreated)
        XCTAssertEqual(viewClassNames(button.subviews), ["View", "ImageView"])
    }

    func testFlagOnTouchReferenceIsAPlainViewWithTheGlassGeometry() {
        GlassChromeReuse.isEnabled = true
        let button = makeButton()
        button.setGlassEffect(size: NSMakeSize(30, 30))
        button.setGlassEffectHidden(true)
        button.updateLayout()
        let reference = button.interactiveGlassView
        XCTAssertNotNil(reference)
        XCTAssertFalse(reference is LiquidGlassView)
        XCTAssertEqual(reference?.frame, NSMakeRect(5, 5, 30, 30))
        XCTAssertEqual(reference?.bounds.size, NSMakeSize(30, 30))
    }

    func testFlagOnVisibleGlassIsBuiltOnFirstLayoutWithTheSameFrameAsEager() {
        let eager = makeButton()
        eager.setGlassEffect(size: NSMakeSize(30, 30))
        eager.updateLayout()
        let eagerFrame = eager.glassViewIfCreated?.frame

        GlassChromeReuse.isEnabled = true
        let button = makeButton()
        button.setGlassEffect(size: NSMakeSize(30, 30))
        XCTAssertEqual(glassCount(button), 0)
        button.updateLayout()
        XCTAssertEqual(glassCount(button), 1)
        XCTAssertEqual(button.glassViewIfCreated?.frame, eagerFrame)
        XCTAssertEqual(button.interactiveGlassView?.frame, eagerFrame)
        XCTAssertEqual(viewClassNames(button.subviews), ["View", "LiquidGlassView", "ImageView"])
    }

    func testFlagOnShowingTheGlassBuildsItAtOnce() {
        GlassChromeReuse.isEnabled = true
        let button = makeButton()
        button.setGlassEffect(size: NSMakeSize(40, 40))
        button.setGlassEffectHidden(true)
        button.updateLayout()
        XCTAssertEqual(glassCount(button), 0)
        button.setGlassEffectHidden(false)
        XCTAssertEqual(glassCount(button), 1)
        XCTAssertEqual(button.glassViewIfCreated?.frame, NSMakeRect(0, 0, 40, 40))
        XCTAssertFalse(button.glassViewIfCreated?.isHidden ?? true)
        button.setGlassEffectHidden(true)
        XCTAssertTrue(button.glassViewIfCreated?.isHidden ?? false)
        XCTAssertEqual(glassCount(button), 1)
    }

    func testFlagOnKeepsTheRequestedTintAndAppearanceForTheLateGlass() {
        GlassChromeReuse.isEnabled = true
        let button = makeButton()
        button.setGlassEffect(size: NSMakeSize(40, 40), tintColor: .systemBlue, forceAppearance: .forceDark)
        button.setGlassEffectHidden(true)
        XCTAssertEqual(button.glassForceAppearance, .forceDark)
        button.setGlassEffectHidden(false)
        XCTAssertEqual(button.glassViewIfCreated?.customTint, NSColor.systemBlue)
        XCTAssertEqual(button.glassViewIfCreated?.forceAppearance, .forceDark)
        XCTAssertEqual(button.glassTintColor, NSColor.systemBlue)
    }

    func testFlagOnTintSetBeforeTheGlassExistsReachesIt() {
        GlassChromeReuse.isEnabled = true
        let button = makeButton()
        button.setGlassEffect(size: NSMakeSize(40, 40))
        button.setGlassEffectHidden(true)
        button.glassTintColor = .systemRed
        button.setGlassEffectHidden(false)
        XCTAssertEqual(button.glassViewIfCreated?.customTint, NSColor.systemRed)
    }

    func testFlagOnHitTestStillReturnsTheButton() {
        GlassChromeReuse.isEnabled = true
        let parent = View(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let button = makeButton()
        button.setFrameOrigin(NSMakePoint(10, 10))
        button.setGlassEffect(size: NSMakeSize(40, 40))
        parent.addSubview(button)
        button.updateLayout()
        let target = parent.hitTest(NSMakePoint(30, 30))
        XCTAssertTrue(target === button)
    }

    func testFlagOnSecondSetGlassEffectIsIgnored() {
        GlassChromeReuse.isEnabled = true
        let button = makeButton()
        button.setGlassEffect(size: NSMakeSize(40, 40))
        button.setGlassEffect(size: NSMakeSize(20, 20), tintColor: .red)
        button.updateLayout()
        XCTAssertEqual(glassCount(button), 1)
        XCTAssertEqual(button.subviews.filter { !($0 is LiquidGlassView) && !($0 is ImageView) }.count, 1)
        XCTAssertEqual(button.glassSize, NSMakeSize(40, 40))
    }
}
