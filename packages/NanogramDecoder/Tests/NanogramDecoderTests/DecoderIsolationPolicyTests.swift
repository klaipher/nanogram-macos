import XCTest
@testable import NanogramDecoder

final class DecoderIsolationPolicyTests: XCTestCase {
    private func makeFrame(width: Int = 8, height: Int = 4) -> (UnsafeMutablePointer<UInt8>, Int) {
        let bytesPerRow = width * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
        memset(buffer, 0xAB, bytesPerRow * height)
        return (buffer, bytesPerRow)
    }

    func test_contentThatCrashesTheServiceTwice_isBlankedAndNeverParsedInProcess() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(failureThreshold: 10))
        let backend = IsolatedDecoderBackend(client: client)
        let json = Data("{\"v\":\"evil\"}".utf8)
        let inProcess = Counter()
        let renderer = try XCTUnwrap(backend.makeAnimation(json: json, preferTLottie: true, fallback: {
            inProcess.increment()
            return FakeAnimation(json: json)
        }))
        service.animations.onRender = { [service] index in
            if index == 13 {
                service.dropAllConnections()
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        let (buffer, bytesPerRow) = makeFrame()
        defer { buffer.deallocate() }
        renderer.renderFrame(13, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertEqual(inProcess.value, 0)
        XCTAssertEqual(buffer[0], 0)

        service.animations.onRender = nil
        renderer.renderFrame(14, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertEqual(inProcess.value, 0)
        XCTAssertEqual(buffer[0], 0)

        let created = service.animations.created.count
        XCTAssertNil(backend.makeAnimation(json: json, preferTLottie: true, fallback: {
            inProcess.increment()
            return FakeAnimation(json: json)
        }))
        XCTAssertEqual(inProcess.value, 0)
        XCTAssertEqual(service.animations.created.count, created)
    }

    func test_oneServiceCrash_retriesTheFrameInAFreshServiceInstance() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(failureThreshold: 10))
        let json = Data("{\"v\":\"ok\"}".utf8)
        let inProcess = Counter()
        let renderer = try XCTUnwrap(IsolatedDecoderBackend(client: client).makeAnimation(json: json, preferTLottie: true, fallback: {
            inProcess.increment()
            return nil
        }))
        let crashed = Counter()
        service.animations.onRender = { [service] index in
            if index == 13 && crashed.value == 0 {
                crashed.increment()
                service.dropAllConnections()
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        let (buffer, bytesPerRow) = makeFrame()
        defer { buffer.deallocate() }
        renderer.renderFrame(13, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertEqual(inProcess.value, 0)
        XCTAssertEqual(buffer[0], UInt8(truncatingIfNeeded: 13 + json.count))
        XCTAssertEqual(service.animations.created.count, 2)
    }

    func test_hungService_isNotRetriedInProcess() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(renderTimeout: 0.2, failureThreshold: 10))
        let inProcess = Counter()
        let renderer = try XCTUnwrap(IsolatedDecoderBackend(client: client).makeAnimation(json: Data("{}".utf8), preferTLottie: true, fallback: {
            inProcess.increment()
            return FakeAnimation(json: Data("{}".utf8))
        }))
        service.animations.onRender = { _ in Thread.sleep(forTimeInterval: 1.0) }
        let (buffer, bytesPerRow) = makeFrame()
        defer { buffer.deallocate() }
        let started = Date()
        renderer.renderFrame(5, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9)
        XCTAssertEqual(inProcess.value, 0)
        XCTAssertEqual(buffer[0], 0)
    }

    func test_breakerOpenAfterTheServiceWorked_failsClosedInsteadOfParsingInProcess() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(failureThreshold: 2, cooldown: 30))
        let backend = IsolatedDecoderBackend(client: client)
        service.animations.onRender = { [service] _ in
            service.dropAllConnections()
            Thread.sleep(forTimeInterval: 0.3)
        }
        let (buffer, bytesPerRow) = makeFrame()
        defer { buffer.deallocate() }
        let renderer = try XCTUnwrap(backend.makeAnimation(json: Data("{\"n\":1}".utf8), preferTLottie: true, fallback: { nil }))
        renderer.renderFrame(1, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertFalse(client.isAvailable)
        let inProcess = Counter()
        let next = backend.makeAnimation(json: Data("{\"n\":\"next\"}".utf8), preferTLottie: true, fallback: {
            inProcess.increment()
            return FakeAnimation(json: Data("{}".utf8))
        })
        XCTAssertNil(next)
        XCTAssertEqual(inProcess.value, 0)
    }

    func test_serviceThatNeverStarts_fallsBackInProcess() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(openTimeout: 0.5))
        service.listener.invalidate()
        let fallbackAnimation = FakeAnimation(json: Data("{}".utf8))
        let renderer = IsolatedDecoderBackend(client: client).makeAnimation(json: Data("{}".utf8), preferTLottie: true, fallback: { fallbackAnimation })
        XCTAssertTrue(renderer === fallbackAnimation)
    }

    func test_afterReconnect_anAnimationNeverRendersAnotherAnimationsSession() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(failureThreshold: 10))
        let backend = IsolatedDecoderBackend(client: client)
        let first = Data("{\"first\":1}".utf8)
        let second = Data("{\"second-is-longer\":2}".utf8)
        let a = try XCTUnwrap(backend.makeAnimation(json: first, preferTLottie: true, fallback: { nil }))
        for _ in 0..<100 {
            a.setColor(DecoderColor(red: 1, green: 0, blue: 0, alpha: 1), keyPath: "k")
        }
        a.setColor(DecoderColor(red: 0, green: 0, blue: 1, alpha: 1), keyPath: "k")
        service.dropAllConnections()
        Thread.sleep(forTimeInterval: 0.2)
        let b = try XCTUnwrap(backend.makeAnimation(json: second, preferTLottie: true, fallback: { nil }))
        let (buffer, bytesPerRow) = makeFrame()
        defer { buffer.deallocate() }
        a.renderFrame(3, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertEqual(buffer[0], UInt8(truncatingIfNeeded: 3 + first.count))
        b.renderFrame(3, into: buffer, width: 8, height: 4, bytesPerRow: Int32(bytesPerRow))
        XCTAssertEqual(buffer[0], UInt8(truncatingIfNeeded: 3 + second.count))
        let reopened = try XCTUnwrap(service.animations.created.last(where: { $0.json == first }))
        XCTAssertEqual(reopened.colors, ["k:0.0,0.0,1.0,1.0"])
    }

    func test_concurrentFailuresOnOneConnection_countAsOneServiceFailure() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(failureThreshold: 2))
        let first = try client.openAnimation(Data("{}".utf8), preferTLottie: true)
        let second = try client.openAnimation(Data("{}".utf8), preferTLottie: true)
        service.animations.onRender = { [service] _ in
            Thread.sleep(forTimeInterval: 0.1)
            service.dropAllConnections()
            Thread.sleep(forTimeInterval: 0.2)
        }
        let group = DispatchGroup()
        for session in [first, second] {
            group.enter()
            Thread.detachNewThread {
                _ = try? client.renderFrame(session, index: 1, width: 8, height: 4, bytesPerRow: 32)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(client.isAvailable)
    }

    func test_imageThatCrashesTheServiceTwice_isRefusedAndNotDecodedInProcess() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(failureThreshold: 10))
        let backend = IsolatedDecoderBackend(client: client)
        let png = samplePNG(width: 8, height: 8)
        XCTAssertEqual(backend.decodeImage(samplePNG(width: 4, height: 4), maxPixelSize: 4).bitmapWidth, 4)
        service.imageHook.value = { [service] in
            service.dropAllConnections()
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertEqual(backend.decodeImage(png, maxPixelSize: 8), .refused)
        service.imageHook.value = nil
        XCTAssertEqual(backend.decodeImage(png, maxPixelSize: 8), .refused)
        XCTAssertEqual(backend.decodeImage(samplePNG(width: 2, height: 2), maxPixelSize: 2).bitmapWidth, 2)
    }

    func test_imageDecode_whenTheServiceNeverStarts_isLeftToTheApp() throws {
        let service = TestService()
        let client = service.makeClient(configuration: .init(imageTimeout: 0.5))
        service.listener.invalidate()
        XCTAssertEqual(IsolatedDecoderBackend(client: client).decodeImage(samplePNG(width: 4, height: 4), maxPixelSize: 4), .unavailable)
    }

    func test_unreadableImage_isRefusedRatherThanHandedToAnInProcessDecoder() throws {
        let service = TestService()
        let client = service.makeClient()
        XCTAssertEqual(IsolatedDecoderBackend(client: client).decodeImage(Data("not an image".utf8), maxPixelSize: 4), .refused)
    }

    func test_hostileImageReply_isRejectedWithoutCrashingTheApp() throws {
        let hostile = HostileImageService()
        let client = hostile.makeClient()
        XCTAssertThrowsError(try client.decodeImage(samplePNG(width: 4, height: 4), maxPixelSize: 4)) { error in
            XCTAssertEqual(error as? DecoderError, .badReply)
        }
        hostile.imageReply = (Data(count: 5000 * 4 * 1), 5000, 1, 5000 * 4)
        XCTAssertThrowsError(try client.decodeImage(samplePNG(width: 4, height: 4), maxPixelSize: 4)) { error in
            XCTAssertEqual(error as? DecoderError, .badReply)
        }
    }
}

final class DecoderServiceLifetimeTests: XCTestCase {
    func test_serviceReleasesAConnectionsSessionsWhenTheClientHangsUp() throws {
        let service = TestService()
        let client = service.makeClient()
        _ = try client.openAnimation(Data("{}".utf8), preferTLottie: true)
        XCTAssertEqual(service.delegate.connectionCount, 1)
        client.resetConnection()
        let deadline = Date().addingTimeInterval(3)
        while service.delegate.connectionCount > 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(service.delegate.connectionCount, 0)
    }
}

extension IsolatedImageOutcome {
    var bitmapWidth: Int? {
        if case let .decoded(bitmap) = self {
            return bitmap.width
        }
        return nil
    }
}
