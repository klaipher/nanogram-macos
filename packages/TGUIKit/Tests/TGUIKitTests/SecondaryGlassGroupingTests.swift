import XCTest
import AppKit
@testable import TGUIKit

final class SecondaryGlassGroupingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
    }

    override func tearDown() {
        System.liquidGlass = false
        UserDefaults.standard.removeObject(forKey: SecondaryGlassGrouping.defaultsKey)
        super.tearDown()
    }

    private func modes() -> [Bool] {
        return System.liquidGlassAvailable ? [false, true] : [false]
    }

    func testFlagIsOffByDefaultAndReadsTheDefaultsKey() {
        UserDefaults.standard.removeObject(forKey: SecondaryGlassGrouping.defaultsKey)
        XCTAssertFalse(SecondaryGlassGrouping.isEnabled)
        SecondaryGlassGrouping.setEnabled(true)
        XCTAssertTrue(SecondaryGlassGrouping.isEnabled)
        SecondaryGlassGrouping.setEnabled(false)
        XCTAssertFalse(SecondaryGlassGrouping.isEnabled)
    }

    func testSpacingNeverMergesGlassThatIsApartToday() {
        XCTAssertEqual(SecondaryGlassGrouping.containerSpacing(minimumGap: 0), 0)
        XCTAssertEqual(SecondaryGlassGrouping.containerSpacing(minimumGap: 1), 0)
        XCTAssertEqual(SecondaryGlassGrouping.containerSpacing(minimumGap: 2), 1)
        XCTAssertEqual(SecondaryGlassGrouping.containerSpacing(minimumGap: 8), 5)
        XCTAssertEqual(SecondaryGlassGrouping.containerSpacing(minimumGap: 100), 5)
        XCTAssertEqual(SecondaryGlassGrouping.containerSpacing(minimumGap: -4), 0)
        XCTAssertEqual(SecondaryGlassGrouping.containerSpacing(minimumGap: .infinity), 5)
        XCTAssertEqual(SecondaryGlassGrouping.containerSpacing(minimumGap: .nan), 0)
        for gap in stride(from: CGFloat(0), through: 12, by: 0.5) {
            XCTAssertLessThan(SecondaryGlassGrouping.containerSpacing(minimumGap: gap), max(gap, 0.0001))
        }
    }

    func testMakeReturnsNilWhenTheFlagIsOff() {
        let host = NSView(frame: NSMakeRect(0, 0, 300, 52))
        let glass = LiquidGlassView(frame: .zero, cornerRadius: 19)
        host.addSubview(glass)
        XCTAssertNil(SecondaryGlassGroup.make(isEnabled: false, host: host, glasses: [glass], minimumGap: 8, flipped: true))
        XCTAssertTrue(glass.superview === host)
    }

    func testAdoptingMovesGlassIntoTheContainerBelowTheHostContent() {
        for liquidGlass in modes() {
            System.liquidGlass = liquidGlass
            let host = NSView(frame: NSMakeRect(0, 0, 300, 52))
            let button = NSView(frame: NSMakeRect(10, 10, 30, 30))
            let first = LiquidGlassView(frame: .zero, cornerRadius: 19)
            let second = LiquidGlassView(frame: .zero, cornerRadius: 19)
            host.addSubview(first)
            host.addSubview(button)
            let group = SecondaryGlassGroup.make(isEnabled: true, host: host, glasses: [first, second], minimumGap: 8, flipped: true)
            XCTAssertNotNil(group, "liquidGlass \(liquidGlass)")
            XCTAssertTrue(host.subviews.first === group?.container, "liquidGlass \(liquidGlass)")
            XCTAssertTrue(host.subviews.last === button, "liquidGlass \(liquidGlass)")
            XCTAssertFalse(first.superview === host)
            XCTAssertTrue(first.superview === group?.container.glassContent)
            XCTAssertTrue(second.superview === group?.container.glassContent)
            XCTAssertEqual(group?.container.ghosts.count, 2)
        }
    }

    func testPlaceKeepsTheRequestedFrameInHostCoordinates() {
        for liquidGlass in modes() {
            System.liquidGlass = liquidGlass
            let host = NSView(frame: NSMakeRect(0, 0, 300, 52))
            let glass = LiquidGlassView(frame: .zero, cornerRadius: 19)
            let group = SecondaryGlassGroup.make(isEnabled: true, host: host, glasses: [glass], minimumGap: 8, flipped: true)!
            group.updateLayout(size: host.bounds.size)
            let target = NSMakeRect(10, 7, 110, 38)
            group.place(glass, frame: target)
            XCTAssertEqual(glass.frame, target, "liquidGlass \(liquidGlass)")
            if liquidGlass {
                XCTAssertEqual(glass.effectView.frame, target)
            }
            XCTAssertEqual(group.container.frame, host.bounds)
            XCTAssertEqual(group.container.glassContent.frame, host.bounds)
        }
    }

    func testGroupFollowsHostResize() {
        let host = NSView(frame: NSMakeRect(0, 0, 300, 52))
        let glass = LiquidGlassView(frame: .zero, cornerRadius: 19)
        let group = SecondaryGlassGroup.make(isEnabled: true, host: host, glasses: [glass], minimumGap: 8, flipped: true)!
        group.updateLayout(size: NSMakeSize(300, 52))
        group.updateLayout(size: NSMakeSize(420, 52))
        XCTAssertEqual(group.container.frame.size, NSMakeSize(420, 52))
    }

    func testSpacingIsAppliedToTheContainer() {
        let host = NSView(frame: NSMakeRect(0, 0, 300, 52))
        let glass = LiquidGlassView(frame: .zero, cornerRadius: 19)
        let group = SecondaryGlassGroup.make(isEnabled: true, host: host, glasses: [glass], minimumGap: 2, flipped: true)!
        XCTAssertEqual(group.container.glassContainer.spacing, 1)
    }
}
