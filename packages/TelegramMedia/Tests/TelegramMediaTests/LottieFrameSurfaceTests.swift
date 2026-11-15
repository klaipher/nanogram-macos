import XCTest
import IOSurface
import TGUIKit
@testable import TelegramMedia

final class LottieFrameSurfaceTests: XCTestCase {
    private let points = CGSize(width: 104, height: 104)
    private let key = LottieAnimationEntryKey(key: .bundle("surface-ring"), size: CGSize(width: 104, height: 104), backingScale: 2)

    private func makeFrameData(seed: UInt8) -> Data {
        let width = Int(points.width) * 2
        let height = Int(points.height) * 2
        let bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: width)
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { buffer in
            let bytes = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let pixel = bytes + y * bytesPerRow + x * 4
                    let alpha = UInt8((x + y) % 256)
                    pixel[0] = UInt8((Int(seed) + x) % 256) / 2 & alpha
                    pixel[1] = UInt8(y % 256) & alpha
                    pixel[2] = seed & alpha
                    pixel[3] = alpha
                }
            }
        }
        return data
    }

    private func makeFrame(seed: UInt8) -> RenderedLottieFrame {
        return RenderedLottieFrame(key: key, fps: 60, frame: Int32(seed), size: points, data: makeFrameData(seed: seed), backingScale: 2)
    }

    private var clock: Double = 1000

    override func setUp() {
        super.setUp()
        LottieFrameSurfacePool.shared.now = { [unowned self] in self.clock }
    }

    override func tearDown() {
        LottieFrameSurfacePool.shared.now = { CFAbsoluteTimeGetCurrent() }
        super.tearDown()
    }

    func testFramesCarryAnIOSurfaceWithTheRenderedPixels() throws {
        let data = makeFrameData(seed: 77)
        let frame = RenderedLottieFrame(key: key, fps: 60, frame: 1, size: points, data: data, backingScale: 2)
        let surface = try XCTUnwrap(frame.surface?.surface)
        XCTAssertEqual(surface.width, 208)
        XCTAssertEqual(surface.height, 208)
        XCTAssertNotNil(IOSurfaceCopyValue(surface, kIOSurfaceColorSpace))
        surface.lock(options: .readOnly, seed: nil)
        defer {
            surface.unlock(options: .readOnly, seed: nil)
        }
        let bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: 208)
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        data.withUnsafeBytes { buffer in
            let source = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in [0, 50, 207] {
                XCTAssertEqual(memcmp(base + y * surface.bytesPerRow, source + y * bytesPerRow, 208 * 4), 0, "row \(y)")
            }
        }
        let image = try XCTUnwrap(frame.image)
        XCTAssertEqual(image.width, 208)
        let layer = CALayer()
        layer.setLottieFrame(frame)
        XCTAssertTrue((layer.contents as AnyObject?) === surface)
    }

    func testSteadyPlaybackCyclesThroughAFewSurfaces() {
        let layer = CALayer()
        let before = LottieFrameSurfacePool.shared.createdCount
        var queued: [RenderedLottieFrame] = []
        for index in 0 ..< 300 {
            queued.append(makeFrame(seed: UInt8(index % 256)))
            if queued.count > 2 {
                layer.setLottieFrame(queued.removeFirst())
            }
            clock += 1.0 / 60.0
        }
        XCTAssertLessThanOrEqual(LottieFrameSurfacePool.shared.createdCount - before, 8)
    }

    func testTheShownSurfaceIsNeverReused() throws {
        let layer = CALayer()
        layer.setLottieFrame(makeFrame(seed: 1))
        let shown = try XCTUnwrap(layer.contents as AnyObject?)
        for seed in 2 ..< 40 {
            let next = makeFrame(seed: UInt8(seed))
            XCTAssertFalse(next.surface?.surface === shown)
            clock += 1.0
        }
    }

    func testAReplacedSurfaceWaitsBeforeReuse() throws {
        let layer = CALayer()
        layer.setLottieFrame(makeFrame(seed: 1))
        let first = try XCTUnwrap(layer.contents as AnyObject?)
        layer.setLottieFrame(makeFrame(seed: 2))
        XCTAssertFalse(makeFrame(seed: 3).surface?.surface === first)
        clock += 0.2
        var reused = false
        for seed in 4 ..< 12 {
            let frame = makeFrame(seed: UInt8(seed))
            if frame.surface?.surface === first {
                reused = true
            }
        }
        XCTAssertTrue(reused)
    }
}

final class LottieFrameSurfaceTrimTests: XCTestCase {
    func testIdleSurfacesOfAnySizeAreDropped() {
        var clock: Double = 5000
        let pool = LottieFrameSurfacePool.shared
        pool.now = { clock }
        defer {
            pool.now = { CFAbsoluteTimeGetCurrent() }
        }
        let bytes = [UInt8](repeating: 0x80, count: 64 * 4 * 64)
        var lease = bytes.withUnsafeBytes { pool.surface(copying: $0.baseAddress!, width: 64, height: 64, bytesPerRow: 256, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
        XCTAssertNotNil(lease)
        lease = nil
        let before = pool.retainedCount
        clock += 10
        let other = bytes.withUnsafeBytes { pool.surface(copying: $0.baseAddress!, width: 32, height: 32, bytesPerRow: 128, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
        XCTAssertNotNil(other)
        XCTAssertLessThan(pool.retainedCount, before + 1)
    }

    func testIdleSurfacesAreDroppedByALowFrequencyTrimWhenNothingTakesNewOnes() {
        var clock: Double = 2000
        var scheduled: [(Double, () -> Void)] = []
        let pool = LottieFrameSurfacePool.shared
        pool.now = { clock }
        pool.scheduleTrim = { delay, work in scheduled.append((delay, work)) }
        defer {
            pool.now = { CFAbsoluteTimeGetCurrent() }
            pool.scheduleTrim = LottieFrameSurfacePool.defaultScheduleTrim
        }
        clock += 100
        let bytes = [UInt8](repeating: 0x40, count: 48 * 4 * 48)
        var leases = (0 ..< 3).map { _ in bytes.withUnsafeBytes { pool.surface(copying: $0.baseAddress!, width: 48, height: 48, bytesPerRow: 192, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) } }
        XCTAssertEqual(leases.compactMap { $0 }.count, 3)
        let before = pool.retainedCount
        XCTAssertTrue(scheduled.isEmpty)
        leases.removeAll()
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertGreaterThanOrEqual(scheduled[0].0, LottieFrameSurfacePool.idleLifetime)
        clock += 10
        let trim = scheduled.removeFirst().1
        trim()
        XCTAssertLessThanOrEqual(pool.retainedCount, before - 3)
        XCTAssertTrue(scheduled.isEmpty)
    }
}
