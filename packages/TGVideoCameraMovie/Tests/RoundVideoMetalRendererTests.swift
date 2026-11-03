import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import ObjectiveC
import XCTest
import TGVideoCameraMovie

private let installShaderLookup: Void = {
    let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Resources/shaders").standardized
    let selector = #selector(Bundle.path(forResource:ofType:))
    guard let method = class_getInstanceMethod(Bundle.self, selector) else {
        return
    }
    typealias Lookup = @convention(c) (AnyObject, Selector, NSString?, NSString?) -> NSString?
    let original = unsafeBitCast(method_getImplementation(method), to: Lookup.self)
    let replacement: @convention(block) (AnyObject, NSString?, NSString?) -> NSString? = { bundle, name, type in
        if let found = original(bundle, selector, name, type) {
            return found
        }
        if let name = name as String?, let type = type as String?, name == "VideoMessage" {
            let path = shaders.appendingPathComponent("\(name).\(type)").path
            if FileManager.default.fileExists(atPath: path) {
                return path as NSString
            }
        }
        return nil
    }
    method_setImplementation(method, imp_implementationWithBlock(replacement))
}()

private enum Pattern: CaseIterable {
    case gradient
    case skin
    case detail
}

private func makeCameraFrame(_ pattern: Pattern, width: Int = 1280, height: Int = 720) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &pixelBuffer)
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
            var r = 0.0, g = 0.0, b = 0.0
            switch pattern {
            case .gradient:
                r = Double(x) / Double(width - 1) * 255
                g = Double(y) / Double(height - 1) * 255
                b = 128 + 127 * sin(Double(x) / 37) * cos(Double(y) / 23)
            case .skin:
                let dx = (Double(x) - Double(width) * 0.55) / (Double(height) * 0.3)
                let dy = (Double(y) - Double(height) * 0.45) / (Double(height) * 0.38)
                let shade = 0.75 + 0.25 * Double(y) / Double(height)
                let face = dx * dx + dy * dy < 1 ? 1.0 : 0.55
                r = 224 * shade * face
                g = 172 * shade * face
                b = 105 * shade * face
            case .detail:
                let checker = ((x / 3) + (y / 3)) % 2 == 0
                r = checker ? 230 : 20
                g = Double((x * 7 + y * 3) % 256)
                b = checker ? 40 : 200
            }
            pixel[0] = UInt8(max(0, min(255, b.rounded())))
            pixel[1] = UInt8(max(0, min(255, g.rounded())))
            pixel[2] = UInt8(max(0, min(255, r.rounded())))
            pixel[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

private func makeImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    draw(context)
    return context.makeImage()!
}

private let planeFrameCount = 6

private func decoration() -> (CGImage, CGImage) {
    let watermark = makeImage(width: 96, height: 96) { context in
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.6))
        context.fill(CGRect(x: 8, y: 8, width: 80, height: 40))
        context.setFillColor(CGColor(red: 0, green: 0.4, blue: 1, alpha: 1))
        context.fill(CGRect(x: 30, y: 50, width: 36, height: 36))
    }
    let planes = makeImage(width: 64, height: 64 * planeFrameCount) { context in
        for index in 0 ..< planeFrameCount {
            let shade = CGFloat(index) / CGFloat(planeFrameCount)
            context.setFillColor(CGColor(red: shade, green: 1 - shade, blue: 0.5, alpha: 0.9))
            context.fillEllipse(in: CGRect(x: 8, y: CGFloat(index * 64 + 8), width: 48, height: 40))
        }
    }
    return (watermark, planes)
}

private struct Comparison {
    var insideMax = 0
    var insideMean = 0.0
    var outsideMax = 0
    var outsideMean = 0.0
}

private func compare(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer) -> Comparison {
    CVPixelBufferLockBaseAddress(lhs, .readOnly)
    CVPixelBufferLockBaseAddress(rhs, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(lhs, .readOnly)
        CVPixelBufferUnlockBaseAddress(rhs, .readOnly)
    }
    let width = CVPixelBufferGetWidth(lhs)
    let height = CVPixelBufferGetHeight(lhs)
    let a = CVPixelBufferGetBaseAddress(lhs)!.assumingMemoryBound(to: UInt8.self)
    let b = CVPixelBufferGetBaseAddress(rhs)!.assumingMemoryBound(to: UInt8.self)
    let strideA = CVPixelBufferGetBytesPerRow(lhs)
    let strideB = CVPixelBufferGetBytesPerRow(rhs)
    var result = Comparison()
    var insideSum = 0, insideCount = 0, outsideSum = 0, outsideCount = 0
    for y in 0 ..< height {
        for x in 0 ..< width {
            let cx = (Double(x) + 0.5) / Double(width) * 2 - 1
            let cy = (Double(y) + 0.5) / Double(height) * 2 - 1
            let radius = (cx * cx + cy * cy).squareRoot()
            var diff = 0
            for channel in 0 ..< 3 {
                diff = max(diff, abs(Int(a[y * strideA + x * 4 + channel]) - Int(b[y * strideB + x * 4 + channel])))
            }
            if radius < 0.97 {
                result.insideMax = max(result.insideMax, diff)
                insideSum += diff
                insideCount += 1
            } else if radius > 1.03 {
                result.outsideMax = max(result.outsideMax, diff)
                outsideSum += diff
                outsideCount += 1
            }
        }
    }
    result.insideMean = Double(insideSum) / Double(max(1, insideCount))
    result.outsideMean = Double(outsideSum) / Double(max(1, outsideCount))
    return result
}

private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (Int, Int, Int) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return (Int(base[offset + 2]), Int(base[offset + 1]), Int(base[offset]))
}

final class RoundVideoMetalRendererTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = installShaderLookup
    }

    private func configure(_ renderer: TGVideoCameraRenderer, mirror: Bool, decorated: Bool, frame: CVPixelBuffer) -> Bool {
        renderer.orientation = .portrait
        renderer.mirror = mirror
        renderer.outputSide = 384
        if decorated {
            let (watermark, planes) = decoration()
            renderer.setDecorationWatermark(watermark, planeFrames: planes, planeFrameCount: planeFrameCount)
            renderer.decorationFrame = 3
        }
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame, formatDescriptionOut: &description)
        return renderer.prepareForInput(with: description!, outputRetainedBufferCountHint: 4)
    }

    private func render(_ renderer: TGVideoCameraRenderer, _ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        return try XCTUnwrap(renderer.copyRenderedPixelBuffer(frame)?.takeRetainedValue())
    }

    func testMetalMatchesTheOpenGLRenderer() throws {
        for decorated in [false, true] {
            for mirror in [true, false] {
                for pattern in Pattern.allCases {
                    let frame = makeCameraFrame(pattern)
                    let gl = TGVideoCameraGLRenderer()
                    let metal = try XCTUnwrap(TGVideoCameraMetalRenderer())
                    XCTAssertTrue(configure(gl, mirror: mirror, decorated: decorated, frame: frame))
                    XCTAssertTrue(configure(metal, mirror: mirror, decorated: decorated, frame: frame))
                    let reference = try render(gl, frame)
                    let output = try render(metal, frame)
                    XCTAssertEqual(CVPixelBufferGetWidth(output), 384)
                    XCTAssertEqual(CVPixelBufferGetHeight(output), 384)
                    let result = compare(output, reference)
                    let label = "\(pattern) mirror \(mirror) decorated \(decorated)"
                    print("RoundVideoMetal \(label): inside max \(result.insideMax) mean \(String(format: "%.3f", result.insideMean)), outside max \(result.outsideMax) mean \(String(format: "%.3f", result.outsideMean))")
                    XCTAssertLessThanOrEqual(result.insideMax, 2, label)
                    XCTAssertLessThan(result.insideMean, 0.5, label)
                    XCTAssertLessThanOrEqual(result.outsideMax, 8, label)
                    XCTAssertLessThan(result.outsideMean, 1.5, label)
                }
            }
        }
    }

    func testMirroredOutputIsTheCentreCropFlippedHorizontally() throws {
        let frame = makeCameraFrame(.gradient)
        let metal = try XCTUnwrap(TGVideoCameraMetalRenderer())
        XCTAssertTrue(configure(metal, mirror: true, decorated: false, frame: frame))
        let output = try render(metal, frame)
        let left = pixel(output, x: 150, y: 192)
        let right = pixel(output, x: 234, y: 192)
        XCTAssertGreaterThan(left.0, right.0 + 20, "mirrored: red (source x) decreases left to right")
        let top = pixel(output, x: 192, y: 120)
        let bottom = pixel(output, x: 192, y: 264)
        XCTAssertLessThan(top.1, bottom.1, "row 0 is the top of the camera frame")
        let centre = pixel(output, x: 192, y: 192)
        XCTAssertEqual(Double(centre.0), 127.5, accuracy: 6)
    }

    func testDecorationIsDrawnOutsideTheCircle() throws {
        let frame = makeCameraFrame(.skin)
        let plain = try XCTUnwrap(TGVideoCameraMetalRenderer())
        let decorated = try XCTUnwrap(TGVideoCameraMetalRenderer())
        XCTAssertTrue(configure(plain, mirror: true, decorated: false, frame: frame))
        XCTAssertTrue(configure(decorated, mirror: true, decorated: true, frame: frame))
        let a = try render(plain, frame)
        let b = try render(decorated, frame)
        XCTAssertFalse(pixel(a, x: 340, y: 340) == pixel(b, x: 340, y: 340), "watermark corner")
        XCTAssertFalse(pixel(a, x: 30, y: 370) == pixel(b, x: 30, y: 370), "plane corner")
        XCTAssertTrue(pixel(a, x: 192, y: 192) == pixel(b, x: 192, y: 192), "inside the circle")
    }

    func testFourKFramesStillRenderAtTheOutputSide() throws {
        let frame = makeCameraFrame(.skin, width: 3840, height: 2160)
        let metal = try XCTUnwrap(TGVideoCameraMetalRenderer())
        XCTAssertTrue(configure(metal, mirror: true, decorated: false, frame: frame))
        let output = try render(metal, frame)
        XCTAssertEqual(CVPixelBufferGetWidth(output), 384)
    }

    func testMetalPoolBuffersCarryRec709AndAreIOSurfaceBacked() throws {
        let frame = makeCameraFrame(.gradient)
        let metal = try XCTUnwrap(TGVideoCameraMetalRenderer())
        XCTAssertTrue(configure(metal, mirror: true, decorated: false, frame: frame))
        let output = try render(metal, frame)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(output))
        XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil) as? String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil) as? String, kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String, kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        let description = try XCTUnwrap(metal.outputFormatDescription)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(description).width, 384)
    }

    func testRenderCostPerFrame() throws {
        func processCPU() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let frames = (0 ..< 4).map { _ in makeCameraFrame(.detail) }
        let renderers: [(String, TGVideoCameraRenderer)] = [("OpenGL", TGVideoCameraGLRenderer()), ("Metal", try XCTUnwrap(TGVideoCameraMetalRenderer()))]
        for (name, renderer) in renderers {
            XCTAssertTrue(configure(renderer, mirror: true, decorated: true, frame: frames[0]))
            for frame in frames {
                _ = try render(renderer, frame)
            }
            let count = 120
            let cpuStart = processCPU()
            let wallStart = CFAbsoluteTimeGetCurrent()
            for index in 0 ..< count {
                _ = try render(renderer, frames[index % frames.count])
            }
            let cpu = (processCPU() - cpuStart) / Double(count) * 1000
            let wall = (CFAbsoluteTimeGetCurrent() - wallStart) / Double(count) * 1000
            print("RoundVideoMetal cost \(name): \(String(format: "%.3f", cpu)) ms CPU, \(String(format: "%.3f", wall)) ms wall per 1280x720 frame")
        }
    }

    func testCaptureOutputIsCappedAt720p() {
        func cap(_ width: Int32, _ height: Int32) -> (Int32, Int32) {
            let result = TGVideoCameraCaptureDimensions(CMVideoDimensions(width: width, height: height))
            return (result.width, result.height)
        }
        XCTAssertTrue(cap(3840, 2160) == (1280, 720))
        XCTAssertTrue(cap(1920, 1080) == (1280, 720))
        XCTAssertTrue(cap(1280, 720) == (1280, 720))
        XCTAssertTrue(cap(640, 480) == (640, 480))
        XCTAssertTrue(cap(4032, 3024) == (960, 720))
        XCTAssertTrue(cap(1080, 1920) == (720, 1280))
        XCTAssertTrue(cap(1552, 1552) == (720, 720))
    }
}
