import AVFoundation
import CoreGraphics
import XCTest
import TGVideoCameraMovie
@testable import MediaRecorderUI

private final class RecordingRenderer: NSObject, TGVideoCameraRenderer {
    var outputFormatDescription: CMFormatDescription! { nil }
    var orientation: AVCaptureVideoOrientation = .portrait
    var mirror: Bool = false
    var opacity: CGFloat = 1
    var hasPreviousPixelbuffer: Bool { false }
    var decorationFrame: Int = 0
    var outputSide: Int = 0
    private(set) var decorationCalls = 0

    func setDecorationWatermark(_ watermark: CGImage!, planeFrames: CGImage!, planeFrameCount: Int) {
        decorationCalls += 1
    }

    func prepareForInput(with inputFormatDescription: CMFormatDescription!, outputRetainedBufferCountHint: Int) -> Bool { true }
    func reset() {}
    func copyRenderedPixelBuffer(_ pixelBuffer: CVPixelBuffer!) -> Unmanaged<CVPixelBuffer>! { nil }
    func setPreviousPixelBuffer(_ previousPixelBuffer: CVPixelBuffer!) {}
}

private func solidImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

final class RoundVideoDecorationTests: XCTestCase {
    func testPipelineDrawsNoPlaneOrWatermark() {
        let renderer = RecordingRenderer()
        var providerCalls = 0
        applyRoundVideoDecoration(to: renderer, decoration: {
            providerCalls += 1
            return (watermark: solidImage(width: 32, height: 32), planeFrames: solidImage(width: 68, height: 68 * 27))
        })
        XCTAssertEqual(renderer.decorationCalls, 0)
        XCTAssertEqual(providerCalls, 0)
    }
}
