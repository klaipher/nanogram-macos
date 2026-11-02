import XCTest
import AppKit
import QuartzCore
@testable import TGUIKit

@available(macOS 12.0, *)
final class CAAnimationFrameRateTests: XCTestCase {
    private let decorative = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
    }

    private func infiniteAnimations(in layer: CALayer) -> [CAAnimation] {
        var result: [CAAnimation] = []
        for key in layer.animationKeys() ?? [] {
            if let animation = layer.animation(forKey: key), animation.repeatCount.isInfinite || animation.repeatCount >= 1000 {
                result.append(animation)
            }
        }
        for sublayer in layer.sublayers ?? [] {
            result.append(contentsOf: self.infiniteAnimations(in: sublayer))
        }
        return result
    }

    func testDecorativeLoopHelperCapsAtSixty() {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.repeatCount = .infinity
        animation.setDecorativeLoopFrameRate()
        XCTAssertEqual(animation.preferredFrameRateRange, self.decorative)
    }

    func testFiniteAnimationsKeepTheDefault() {
        let layer = CALayer()
        for timing in [CAMediaTimingFunctionName.easeOut, .spring] {
            let animation = layer.makeAnimation(from: 0 as NSNumber, to: 100 as NSNumber, keyPath: "position.x", timingFunction: timing, duration: 0.3)
            XCTAssertEqual(animation.preferredFrameRateRange, .default, timing.rawValue)
        }
    }

    func testSpinnerLoopsAreDecorative() throws {
        let view = InfiniteProgressView(color: .black, lineWidth: 2)
        view.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        defer {
            view.removeFromSuperview()
            window.close()
        }
        let animations = self.infiniteAnimations(in: try XCTUnwrap(view.layer))
        XCTAssertGreaterThanOrEqual(animations.count, 2)
        for animation in animations {
            XCTAssertEqual(animation.preferredFrameRateRange, self.decorative, "\(animation)")
        }
    }

    func testSilhouetteShimmerLoopIsDecorative() {
        let layer = SilhouetteShimmerLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 100, height: 20)
        layer.update(foregroundColor: .gray, shimmeringColor: .white, data: nil, size: CGSize(width: 100, height: 20), imageSize: NSSize(width: 100, height: 20))
        let animations = self.infiniteAnimations(in: layer)
        XCTAssertFalse(animations.isEmpty)
        for animation in animations {
            XCTAssertEqual(animation.preferredFrameRateRange, self.decorative, "\(animation)")
        }
    }
}
