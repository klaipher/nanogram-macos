import XCTest
import AppKit
@testable import TGUIKit

final class TransformImageProtectedLayerTests: XCTestCase {
    private func protectedLayer(of view: NSView) -> CaptureProtectedContentLayer? {
        return view.layer?.sublayers?.compactMap { $0 as? CaptureProtectedContentLayer }.first
    }

    func testProtectedLayerFollowsSetFrameSize() {
        let view = TransformImageView(frame: .zero)
        view.preventsCapture = true
        view.setFrameSize(NSSize(width: 200, height: 150))
        XCTAssertEqual(protectedLayer(of: view)?.frame, view.bounds)
    }

    func testProtectedLayerFollowsFrameAssignment() {
        let view = TransformImageView(frame: .zero)
        view.preventsCapture = true
        view.frame = NSRect(x: 10, y: 20, width: 120, height: 90)
        XCTAssertEqual(protectedLayer(of: view)?.frame, view.bounds)
    }

    func testProtectedLayerTakesTheCurrentSizeWhenTurnedOn() {
        let view = TransformImageView(frame: .zero)
        view.setFrameSize(NSSize(width: 80, height: 60))
        view.preventsCapture = true
        XCTAssertEqual(protectedLayer(of: view)?.frame, view.bounds)
    }
}
