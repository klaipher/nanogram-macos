import Foundation
import os

public final class DecoderXPCClient: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var limits: DecoderLimits
        public var openTimeout: TimeInterval
        public var renderTimeout: TimeInterval
        public var imageTimeout: TimeInterval
        public var failureThreshold: Int
        public var cooldown: TimeInterval
        public var now: @Sendable () -> Date

        public init(limits: DecoderLimits = .standard, openTimeout: TimeInterval = 3, renderTimeout: TimeInterval = 1.5, imageTimeout: TimeInterval = 3, failureThreshold: Int = 3, cooldown: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
            self.limits = limits
            self.openTimeout = openTimeout
            self.renderTimeout = renderTimeout
            self.imageTimeout = imageTimeout
            self.failureThreshold = failureThreshold
            self.cooldown = cooldown
            self.now = now
        }
    }

    public struct OpenedAnimation: Equatable, Sendable {
        public let session: Int64
        public let startFrame: Int32
        public let endFrame: Int32
        public let fps: Int32
        public let generation: Int
    }

    public let configuration: Configuration
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var generation = 0
    private var lastCountedFailureGeneration = -1
    private var consecutiveFailures = 0
    private var disabledUntil: Date?
    private var answered = false

    public init(configuration: Configuration = Configuration(), makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.configuration = configuration
        self.makeConnection = makeConnection
    }

    public convenience init(configuration: Configuration = Configuration(), serviceName: String = DecoderService.machServiceName) {
        self.init(configuration: configuration, makeConnection: { NSXPCConnection(serviceName: serviceName) })
    }

    public var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = disabledUntil else {
            return true
        }
        if configuration.now() >= until {
            disabledUntil = nil
            consecutiveFailures = 0
            return true
        }
        return false
    }

    public var hasServiceAnswered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return answered
    }

    public func openAnimation(_ data: Data, preferTLottie: Bool) throws -> OpenedAnimation {
        guard data.count <= configuration.limits.maxAnimationBytes else {
            throw DecoderError.inputTooLarge
        }
        let link = currentConnection()
        let generation = link.generation
        return try perform(on: link, timeout: configuration.openTimeout, resetsFailureCount: false) { proxy, complete in
            proxy.openAnimation(data, preferTLottie: preferTLottie, reply: { session, start, end, fps, error in
                if let error {
                    complete(.failure(DecoderError(rawValue: error) ?? .badReply))
                } else if session > 0 {
                    complete(.success(OpenedAnimation(session: session, startFrame: start, endFrame: end, fps: fps, generation: generation)))
                } else {
                    complete(.failure(.badReply))
                }
            })
        }
    }

    public func renderFrame(_ opened: OpenedAnimation, index: Int32, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        let limits = configuration.limits
        guard width > 0, height > 0, width <= limits.maxFrameDimension, height <= limits.maxFrameDimension, bytesPerRow >= width * 4, bytesPerRow <= limits.maxFrameBytes, bytesPerRow * height <= limits.maxFrameBytes else {
            throw DecoderError.invalidDimensions
        }
        guard let link = liveConnection(generation: opened.generation) else {
            throw DecoderError.staleSession
        }
        let expected = bytesPerRow * height
        return try perform(on: link, timeout: configuration.renderTimeout) { proxy, complete in
            proxy.renderFrame(session: opened.session, index: index, width: Int32(clamping: width), height: Int32(clamping: height), bytesPerRow: Int32(clamping: bytesPerRow), reply: { data, error in
                if let error {
                    complete(.failure(DecoderError(rawValue: error) ?? .badReply))
                } else if let data, data.count == expected {
                    complete(.success(data))
                } else {
                    complete(.failure(.badReply))
                }
            })
        }
    }

    public func setColor(_ opened: OpenedAnimation, color: DecoderColor, keyPath: String) {
        guard let link = liveConnection(generation: opened.generation) else {
            return
        }
        (link.connection.remoteObjectProxy as? NanogramDecoderXPCProtocol)?.setColor(session: opened.session, red: color.red, green: color.green, blue: color.blue, alpha: color.alpha, keyPath: keyPath)
    }

    public func closeAnimation(_ opened: OpenedAnimation) {
        guard let link = liveConnection(generation: opened.generation) else {
            return
        }
        (link.connection.remoteObjectProxy as? NanogramDecoderXPCProtocol)?.closeAnimation(session: opened.session)
    }

    public func decodeImage(_ data: Data, maxPixelSize: Int) throws -> DecodedBitmap {
        let limits = configuration.limits
        guard data.count <= limits.maxImageBytes else {
            throw DecoderError.inputTooLarge
        }
        let clamped = Int32(clamping: min(max(maxPixelSize, 1), limits.maxFrameDimension))
        return try perform(on: currentConnection(), timeout: configuration.imageTimeout) { proxy, complete in
            proxy.decodeImage(data, maxPixelSize: clamped, reply: { pixels, width, height, bytesPerRow, error in
                if let error {
                    complete(.failure(DecoderError(rawValue: error) ?? .badReply))
                } else if let pixels, let bitmap = Self.validatedBitmap(pixels: pixels, width: Int(width), height: Int(height), bytesPerRow: Int(bytesPerRow), limits: limits) {
                    complete(.success(bitmap))
                } else {
                    complete(.failure(.badReply))
                }
            })
        }
    }

    static func validatedBitmap(pixels: Data, width: Int, height: Int, bytesPerRow: Int, limits: DecoderLimits) -> DecodedBitmap? {
        guard width > 0, height > 0, width <= limits.maxFrameDimension, height <= limits.maxFrameDimension,
              bytesPerRow >= width * 4, bytesPerRow <= limits.maxFrameBytes, bytesPerRow * height <= limits.maxFrameBytes,
              pixels.count == bytesPerRow * height else {
            return nil
        }
        return DecodedBitmap(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    public func resetConnection() {
        lock.lock()
        let stale = connection
        connection = nil
        lock.unlock()
        stale?.invalidate()
    }

    private struct Link {
        let connection: NSXPCConnection
        let generation: Int
    }

    private func noteFailure(generation failedGeneration: Int) {
        lock.lock()
        let stale = connection != nil && generation == failedGeneration ? connection : nil
        if stale != nil {
            connection = nil
        }
        if failedGeneration > lastCountedFailureGeneration {
            lastCountedFailureGeneration = failedGeneration
            consecutiveFailures += 1
            if consecutiveFailures >= configuration.failureThreshold {
                disabledUntil = configuration.now().addingTimeInterval(configuration.cooldown)
            }
        }
        lock.unlock()
        stale?.invalidate()
    }

    private func noteSuccess() {
        lock.lock()
        consecutiveFailures = 0
        lock.unlock()
    }

    private func noteAnswer() {
        lock.lock()
        answered = true
        lock.unlock()
    }

    private func liveConnection(generation wanted: Int) -> Link? {
        lock.lock()
        defer { lock.unlock() }
        guard let connection, generation == wanted else {
            return nil
        }
        return Link(connection: connection, generation: generation)
    }

    private func forget(_ dead: NSXPCConnection?) {
        lock.lock()
        if let dead, connection === dead {
            connection = nil
        }
        lock.unlock()
    }

    private func currentConnection() -> Link {
        lock.lock()
        defer { lock.unlock() }
        if let connection {
            return Link(connection: connection, generation: generation)
        }
        let fresh = makeConnection()
        generation += 1
        fresh.remoteObjectInterface = NSXPCInterface(with: NanogramDecoderXPCProtocol.self)
        fresh.invalidationHandler = { [weak self, weak fresh] in
            self?.forget(fresh)
        }
        fresh.interruptionHandler = { [weak self, weak fresh] in
            self?.forget(fresh)
            fresh?.invalidate()
        }
        fresh.resume()
        connection = fresh
        return Link(connection: fresh, generation: generation)
    }

    private func perform<T: Sendable>(on link: Link, timeout: TimeInterval, resetsFailureCount: Bool = true, _ body: (NanogramDecoderXPCProtocol, @escaping @Sendable (Result<T, DecoderError>) -> Void) -> Void) throws -> T {
        let box = ReplyBox<T>()
        let proxy = link.connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            let neverAnswered = self.map { !$0.hasServiceAnswered } ?? true
            let unreachable = (error as NSError).code == NSXPCConnectionInvalid && neverAnswered
            box.complete(.failure(unreachable ? .serviceUnavailable : .connectionLost))
        }
        guard let service = proxy as? NanogramDecoderXPCProtocol else {
            throw DecoderError.badReply
        }
        body(service, { [weak self] result in
            self?.noteAnswer()
            box.complete(result)
        })
        let result = box.wait(timeout: timeout) ?? .failure(.timedOut)
        switch result {
        case .success(let value):
            if resetsFailureCount {
                noteSuccess()
            }
            return value
        case .failure(let error):
            if error.countsAsServiceFailure {
                noteFailure(generation: link.generation)
            }
            throw error
        }
    }
}

private final class ReplyBox<T: Sendable>: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let result = OSAllocatedUnfairLock<Result<T, DecoderError>?>(initialState: nil)

    func complete(_ value: Result<T, DecoderError>) {
        let first = result.withLock { current -> Bool in
            guard current == nil else {
                return false
            }
            current = value
            return true
        }
        if first {
            semaphore.signal()
        }
    }

    func wait(timeout: TimeInterval) -> Result<T, DecoderError>? {
        _ = semaphore.wait(timeout: .now() + timeout)
        return result.withLock { $0 }
    }
}
