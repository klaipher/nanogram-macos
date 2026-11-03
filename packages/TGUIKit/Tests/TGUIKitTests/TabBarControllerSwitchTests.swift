import XCTest
import AppKit
@testable import TGUIKit

final class TabBarControllerSwitchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
    }

    private func makeController(tabs: Int) -> (TabBarController, [ViewController]) {
        let controller = TabBarController()
        controller.bar = .init(height: 0)
        controller._frameRect = NSMakeRect(0, 0, 380, 700)
        controller.loadViewIfNeeded()
        var children: [ViewController] = []
        for _ in 0 ..< tabs {
            let child = ViewController()
            child.bar = .init(height: 0)
            let image = testImage(NSSize(width: 24, height: 24))
            controller.add(tab: TabItem(image: image, selectedImage: image, controller: child))
            children.append(child)
        }
        controller.select(index: 0)
        return (controller, children)
    }

    private func contentViews(_ controller: TabBarController, _ children: [ViewController]) -> [NSView] {
        return controller.view.subviews.filter { view in children.contains(where: { $0.isLoaded() && $0.view === view }) }
    }

    func testSwitchingTabsShowsOnlyTheNewContentInTheSameFrame() {
        let (controller, children) = makeController(tabs: 4)
        controller.select(index: 3)
        XCTAssertNil(children[0].view.superview)
        XCTAssertTrue(children[3].view.superview === controller.view)
        XCTAssertEqual(contentViews(controller, children).map { ObjectIdentifier($0) }, [ObjectIdentifier(children[3].view)])
    }

    func testSwitchingTabsDoesNotCrossfadeTheContent() {
        let (controller, children) = makeController(tabs: 4)
        controller.select(index: 2)
        XCTAssertNil(children[2].view.layer?.animation(forKey: "opacity"))
        XCTAssertEqual(children[2].view.layer?.opacity, 1)
        XCTAssertNil(children[0].view.layer?.animation(forKey: "opacity"))
    }

    func testRapidSwitchingBackKeepsExactlyOneVisibleContent() {
        let (controller, children) = makeController(tabs: 4)
        controller.select(index: 1)
        controller.select(index: 0)
        controller.select(index: 3)
        controller.select(index: 0)
        XCTAssertEqual(contentViews(controller, children).map { ObjectIdentifier($0) }, [ObjectIdentifier(children[0].view)])
        XCTAssertNil(children[0].view.layer?.animation(forKey: "opacity"))
        XCTAssertEqual(children[0].view.layer?.opacity, 1)
        XCTAssertTrue(controller.current === children[0])
    }
}
