import XCTest
@testable import NanogramDecoder

final class DecoderXPCTests: XCTestCase {
    private func makeFrame(width: Int = 8, height: Int = 4) -> (UnsafeMutablePointer<UInt8>, Int) {
        let bytesPerRow = width * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
        memset(buffer, 0, bytesPerRow * height)
        return (buffer, bytesPerRow)
    }

    func test_roundTrip_openRenderColorClose() throws {
        let service = TestService()
        let client = service.makeClient()
        let json = Data("{\"v\":\"5.5\"}".utf8)

        let opened = try client.openAnimation(json, preferTLottie: true)
        XCTAssertEqual(opened.startFrame, 0)
        XCTAssertEqual(opened.endFrame, 60)
        XCTAssertEqual(opened.fps, 30)

        let frame = try client.renderFrame(session: opened.session, index: 7, width: 8, height: 4, bytesPerRow: 32)
        XCTAssertEqual(frame.count, 32 * 4)
        XCTAssertEqual(frame[0], UInt8(truncatingIfNeeded: 7 + json.count))

        client.setColor(session: opened.session, color: DecoderColor(red: 1, green: 0.5, blue: 0, alpha: 1), keyPath: "layer.fill")
        _ = try client.renderFrame(session: opened.session, index: 8, width: 8, height: 4, bytesPerRow: 32)
        XCTAssertEqual(service.animations.created.first?.colors, ["layer.fill:1.0,0.5,0.0,1.0"])

        client.closeAnimation(session: opened.session)
        XCTAssertThrowsError(try client.renderFrame(session: opened.session, index: 1, width: 8, height: 4, bytesPerRow: 32)) { error in
            XCTAssertEqual(error as? DecoderError, .unknownSession)
        }
    }

    func test_isolatedRenderer_rendersThroughService() throws {
        let service = TestService()
        let client = service.makeClient()
        let json = Data("{\"v\":\"1\"}".utf8)
        let renderer = try XCTUnwrap(IsolatedDecoderBackend(client: client).makeAnimation(json: json, preferTLottie: false, fallback: { nil }))
        XCTAssertEqual(renderer.endFrame, 60)
        let (buffer, bytesPerRow) = makeFrame()
        defer { buffer.deallocate() }
        renderer.renderFrame(3, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertEqual(buffer[0], UInt8(truncatingIfNeeded: 3 + json.count))
        XCTAssertEqual(service.animations.created.count, 1)
    }

    func test_oversizedAnimation_isRejectedByClientBeforeSending() throws {
        let limits = DecoderLimits(maxAnimationBytes: 64)
        let service = TestService(limits: limits)
        let client = service.makeClient(configuration: .init(limits: limits))
        XCTAssertThrowsError(try client.openAnimation(Data(count: 65), preferTLottie: true)) { error in
            XCTAssertEqual(error as? DecoderError, .inputTooLarge)
        }
        XCTAssertTrue(service.animations.created.isEmpty)
    }

    func test_oversizedAnimation_isRejectedByServiceEvenFromAHostileClient() throws {
        let service = TestService(limits: DecoderLimits(maxAnimationBytes: 64))
        let client = service.makeClient(configuration: .init(limits: DecoderLimits(maxAnimationBytes: 1_000_000)))
        XCTAssertThrowsError(try client.openAnimation(Data(count: 65), preferTLottie: true)) { error in
            XCTAssertEqual(error as? DecoderError, .inputTooLarge)
        }
        XCTAssertTrue(service.animations.created.isEmpty)
    }

    func test_oversizedFrame_isRejectedByService() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(limits: DecoderLimits(maxFrameDimension: 100_000, maxFrameBytes: 1 << 40)))
        let opened = try client.openAnimation(Data("{}".utf8), preferTLottie: true)
        XCTAssertThrowsError(try client.renderFrame(session: opened.session, index: 0, width: 50_000, height: 50_000, bytesPerRow: 200_000)) { error in
            XCTAssertEqual(error as? DecoderError, .invalidDimensions)
        }
        XCTAssertThrowsError(try client.renderFrame(session: opened.session, index: 0, width: 8, height: 4, bytesPerRow: 16)) { error in
            XCTAssertEqual(error as? DecoderError, .invalidDimensions)
        }
    }

    func test_tooManySessions_isRejected() throws {
        let limits = DecoderLimits(maxSessionsPerConnection: 2)
        let service = TestService(limits: limits)
        let client = service.makeClient()
        _ = try client.openAnimation(Data("{}".utf8), preferTLottie: true)
        _ = try client.openAnimation(Data("{}".utf8), preferTLottie: true)
        XCTAssertThrowsError(try client.openAnimation(Data("{}".utf8), preferTLottie: true)) { error in
            XCTAssertEqual(error as? DecoderError, .tooManySessions)
        }
    }

    func test_unparsableAnimation_isReportedWithoutTrippingTheBreaker() throws {
        let service = TestService()
        service.animations.rejectsEverything = true
        let client = service.makeClient(configuration: .init(failureThreshold: 1))
        for _ in 0..<3 {
            XCTAssertThrowsError(try client.openAnimation(Data("{}".utf8), preferTLottie: true)) { error in
                XCTAssertEqual(error as? DecoderError, .rendererUnavailable)
            }
        }
        XCTAssertTrue(client.isAvailable)
    }

    func test_serviceCrashMidRender_fallsBackInProcessAndAppSurvives() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(failureThreshold: 10))
        let json = Data("{\"v\":\"9\"}".utf8)
        let fallbackCount = Counter()
        let fallbackAnimation = FakeAnimation(json: Data("{\"v\":\"fallback\"}".utf8))
        let renderer = try XCTUnwrap(IsolatedDecoderBackend(client: client).makeAnimation(json: json, preferTLottie: true, fallback: {
            fallbackCount.increment()
            return fallbackAnimation
        }))
        renderer.setColor(DecoderColor(red: 0, green: 1, blue: 0, alpha: 1), keyPath: "k")
        service.animations.onRender = { [service] index in
            if index == 13 {
                service.dropAllConnections()
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        let (buffer, bytesPerRow) = makeFrame()
        defer { buffer.deallocate() }
        renderer.renderFrame(12, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertEqual(buffer[0], UInt8(truncatingIfNeeded: 12 + json.count))
        XCTAssertEqual(fallbackCount.value, 0)

        renderer.renderFrame(13, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertEqual(fallbackCount.value, 1)
        XCTAssertEqual(buffer[0], UInt8(truncatingIfNeeded: 13 + fallbackAnimation.json.count))
        XCTAssertEqual(fallbackAnimation.colors, ["k:0.0,1.0,0.0,1.0"])

        renderer.renderFrame(14, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertEqual(fallbackCount.value, 1)
        XCTAssertEqual(buffer[0], UInt8(truncatingIfNeeded: 14 + fallbackAnimation.json.count))
    }

    func test_serviceRestartsCleanlyAfterACrash() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(failureThreshold: 10))
        let first = try client.openAnimation(Data("{}".utf8), preferTLottie: true)
        service.dropAllConnections()
        XCTAssertThrowsError(try client.renderFrame(session: first.session, index: 1, width: 8, height: 4, bytesPerRow: 32))
        let second = try client.openAnimation(Data("{}".utf8), preferTLottie: true)
        let frame = try client.renderFrame(session: second.session, index: 2, width: 8, height: 4, bytesPerRow: 32)
        XCTAssertEqual(frame.count, 128)
    }

    func test_hungService_timesOutAndFallsBack() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(renderTimeout: 0.2, failureThreshold: 10))
        service.animations.onRender = { _ in Thread.sleep(forTimeInterval: 1.0) }
        let fallbackAnimation = FakeAnimation(json: Data("{\"v\":\"fb\"}".utf8))
        let renderer = try XCTUnwrap(IsolatedDecoderBackend(client: client).makeAnimation(json: Data("{}".utf8), preferTLottie: true, fallback: { fallbackAnimation }))
        let (buffer, bytesPerRow) = makeFrame()
        defer { buffer.deallocate() }
        let started = Date()
        renderer.renderFrame(5, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9)
        XCTAssertEqual(buffer[0], UInt8(truncatingIfNeeded: 5 + fallbackAnimation.json.count))
    }

    func test_repeatedFailures_disableTheServiceThenRetryAfterCooldown() throws {
        let service = TestService()
        let clock = TestClock()
        let client = service.makeClient(configuration: .init(failureThreshold: 2, cooldown: 30, now: { clock.now }))
        let backend = IsolatedDecoderBackend(client: client)
        let fallbackAnimation = FakeAnimation(json: Data("{}".utf8))
        service.animations.onRender = { [service] _ in
            service.dropAllConnections()
            Thread.sleep(forTimeInterval: 0.3)
        }
        let (buffer, bytesPerRow) = makeFrame()
        defer { buffer.deallocate() }
        for _ in 0..<2 {
            let renderer = try XCTUnwrap(backend.makeAnimation(json: Data("{}".utf8), preferTLottie: true, fallback: { fallbackAnimation }))
            renderer.renderFrame(1, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        }
        XCTAssertFalse(client.isAvailable)
        let created = service.animations.created.count
        let direct = try XCTUnwrap(backend.makeAnimation(json: Data("{}".utf8), preferTLottie: true, fallback: { fallbackAnimation }))
        XCTAssertTrue(direct === fallbackAnimation)
        XCTAssertEqual(service.animations.created.count, created)

        clock.advance(31)
        service.animations.onRender = nil
        XCTAssertTrue(client.isAvailable)
        let recovered = try XCTUnwrap(backend.makeAnimation(json: Data("{}".utf8), preferTLottie: true, fallback: { fallbackAnimation }))
        XCTAssertFalse(recovered === fallbackAnimation)
        recovered.renderFrame(2, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertEqual(buffer[0], UInt8(truncatingIfNeeded: 2 + 2))
    }

    func test_imageDecode_roundTripAndLimits() throws {
        let service = TestService()
        let client = service.makeClient()
        let png = samplePNG(width: 64, height: 32)
        let bitmap = try client.decodeImage(png, maxPixelSize: 32)
        XCTAssertEqual(bitmap.width, 32)
        XCTAssertEqual(bitmap.height, 16)
        XCTAssertEqual(bitmap.pixels.count, bitmap.bytesPerRow * bitmap.height)
        XCTAssertEqual(bitmap.pixels[2], 255)

        XCTAssertThrowsError(try client.decodeImage(Data("not an image".utf8), maxPixelSize: 32)) { error in
            XCTAssertEqual(error as? DecoderError, .decodeFailed)
        }

        let tiny = DecoderLimits(maxImageBytes: 100)
        let tinyService = TestService(limits: tiny)
        let limited = tinyService.makeClient(configuration: .init(limits: DecoderLimits(maxImageBytes: 1 << 20)))
        XCTAssertThrowsError(try limited.decodeImage(png, maxPixelSize: 32)) { error in
            XCTAssertEqual(error as? DecoderError, .inputTooLarge)
        }
    }

    func test_imageDecode_rejectsPixelBombs() throws {
        let limits = DecoderLimits(maxSourcePixels: 1000)
        XCTAssertThrowsError(try ImageIODecoder.decode(samplePNG(width: 64, height: 64), maxPixelSize: 32, limits: limits)) { error in
            XCTAssertEqual(error as? DecoderError, .inputTooLarge)
        }
    }

    func test_isolatedImageDecode_fallsBackWhenServiceIsGone() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(imageTimeout: 0.5))
        service.dropAllConnections()
        let marker = DecodedBitmap(pixels: Data(count: 4), width: 1, height: 1, bytesPerRow: 4)
        let result = IsolatedDecoderBackend(client: client).decodeImage(samplePNG(width: 4, height: 4), maxPixelSize: 4, fallback: { marker })
        XCTAssertEqual(result?.width, 4)
        service.listener.invalidate()
        let afterShutdown = IsolatedDecoderBackend(client: client).decodeImage(samplePNG(width: 4, height: 4), maxPixelSize: 4, fallback: { marker })
        XCTAssertEqual(afterShutdown, marker)
    }

    func test_perFrameOverhead_isMeasured() throws {
        let service = TestService()
        let client = service.makeClient()
        let width = 512
        let height = 512
        let bytesPerRow = width * 4
        let opened = try client.openAnimation(Data("{}".utf8), preferTLottie: true)
        let direct = FakeAnimation(json: Data("{}".utf8))
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
        defer { buffer.deallocate() }
        let frames = 200

        let directStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<frames {
            direct.renderFrame(Int32(index % 60), into: buffer, width: Int32(width), height: Int32(height), bytesPerRow: Int32(bytesPerRow))
        }
        let directPerFrame = Double(DispatchTime.now().uptimeNanoseconds - directStart) / Double(frames) / 1000

        _ = try client.renderFrame(session: opened.session, index: 0, width: width, height: height, bytesPerRow: bytesPerRow)
        var samples: [Double] = []
        for index in 0..<frames {
            let start = DispatchTime.now().uptimeNanoseconds
            let data = try client.renderFrame(session: opened.session, index: Int32(index % 60), width: width, height: height, bytesPerRow: bytesPerRow)
            _ = data.withUnsafeBytes { raw in
                memcpy(buffer, raw.baseAddress!, raw.count)
            }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        samples.sort()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let p95 = samples[Int(Double(samples.count) * 0.95)]
        print("DECODER-XPC-BENCH 512x512 BGRA frame: in-process fill \(String(format: "%.0f", directPerFrame)) us, via XPC mean \(String(format: "%.0f", mean)) us, p50 \(String(format: "%.0f", samples[samples.count / 2])) us, p95 \(String(format: "%.0f", p95)) us, overhead \(String(format: "%.0f", mean - directPerFrame)) us/frame")
        XCTAssertLessThan(mean, 16_000, "an XPC frame must fit well inside one 60 Hz frame")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}
