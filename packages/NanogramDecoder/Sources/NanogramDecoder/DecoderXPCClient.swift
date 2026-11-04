import Foundation

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
    }

    public let configuration: Configuration
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var consecutiveFailures = 0
    private var disabledUntil: Date?

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

    public func openAnimation(_ data: Data, preferTLottie: Bool) throws -> OpenedAnimation {
        guard data.count <= configuration.limits.maxAnimationBytes else {
            throw DecoderError.inputTooLarge
        }
        return try perform(timeout: configuration.openTimeout, resetsFailureCount: false) { proxy, complete in
            proxy.openAnimation(data, preferTLottie: preferTLottie, reply: { session, start, end, fps, error in
                if let error {
                    complete(.failure(DecoderError(rawValue: error) ?? .badReply))
                } else if session > 0 {
                    complete(.success(OpenedAnimation(session: session, startFrame: start, endFrame: end, fps: fps)))
                } else {
                    complete(.failure(.badReply))
                }
            })
        }
    }

    public func renderFrame(session: Int64, index: Int32, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        let limits = configuration.limits
        guard width > 0, height > 0, width <= limits.maxFrameDimension, height <= limits.maxFrameDimension, bytesPerRow >= width * 4, bytesPerRow * height <= limits.maxFrameBytes else {
            throw DecoderError.invalidDimensions
        }
        let expected = bytesPerRow * height
        return try perform(timeout: configuration.renderTimeout) { proxy, complete in
            proxy.renderFrame(session: session, index: index, width: Int32(clamping: width), height: Int32(clamping: height), bytesPerRow: Int32(clamping: bytesPerRow), reply: { data, error in
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

    public func setColor(session: Int64, color: DecoderColor, keyPath: String) {
        (currentConnection().remoteObjectProxy as? NanogramDecoderXPCProtocol)?.setColor(session: session, red: color.red, green: color.green, blue: color.blue, alpha: color.alpha, keyPath: keyPath)
    }

    public func closeAnimation(session: Int64) {
        (currentConnection().remoteObjectProxy as? NanogramDecoderXPCProtocol)?.closeAnimation(session: session)
    }

    public func decodeImage(_ data: Data, maxPixelSize: Int) throws -> DecodedBitmap {
        guard data.count <= configuration.limits.maxImageBytes else {
            throw DecoderError.inputTooLarge
        }
        let clamped = Int32(clamping: min(max(maxPixelSize, 1), configuration.limits.maxFrameDimension))
        return try perform(timeout: configuration.imageTimeout) { proxy, complete in
            proxy.decodeImage(data, maxPixelSize: clamped, reply: { pixels, width, height, bytesPerRow, error in
                if let error {
                    complete(.failure(DecoderError(rawValue: error) ?? .badReply))
                } else if let pixels, width > 0, height > 0, bytesPerRow >= width * 4, pixels.count == Int(bytesPerRow) * Int(height) {
                    complete(.success(DecodedBitmap(pixels: pixels, width: Int(width), height: Int(height), bytesPerRow: Int(bytesPerRow))))
                } else {
                    complete(.failure(.badReply))
                }
            })
        }
    }

    public func noteFailure() {
        lock.lock()
        consecutiveFailures += 1
        if consecutiveFailures >= configuration.failureThreshold {
            disabledUntil = configuration.now().addingTimeInterval(configuration.cooldown)
        }
        lock.unlock()
    }

    public func resetConnection() {
        lock.lock()
        let stale = connection
        connection = nil
        lock.unlock()
        stale?.invalidate()
    }

    private func noteSuccess() {
        lock.lock()
        consecutiveFailures = 0
        lock.unlock()
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection {
            return connection
        }
        let fresh = makeConnection()
        fresh.remoteObjectInterface = NSXPCInterface(with: NanogramDecoderXPCProtocol.self)
        fresh.invalidationHandler = { [weak self, weak fresh] in
            guard let self, let fresh else {
                return
            }
            self.lock.lock()
            if self.connection === fresh {
                self.connection = nil
            }
            self.lock.unlock()
        }
        fresh.resume()
        connection = fresh
        return fresh
    }

    private func perform<T: Sendable>(timeout: TimeInterval, resetsFailureCount: Bool = true, _ body: (NanogramDecoderXPCProtocol, @escaping @Sendable (Result<T, DecoderError>) -> Void) -> Void) throws -> T {
        let box = ReplyBox<T>()
        let connection = currentConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            box.complete(.failure(.connectionLost))
        }
        guard let service = proxy as? NanogramDecoderXPCProtocol else {
            throw DecoderError.badReply
        }
        body(service, { box.complete($0) })
        let result = box.wait(timeout: timeout) ?? .failure(.timedOut)
        switch result {
        case .success(let value):
            if resetsFailureCount {
                noteSuccess()
            }
            return value
        case .failure(let error):
            if error.countsAsServiceFailure {
                resetConnection()
                noteFailure()
            }
            throw error
        }
    }
}

private final class ReplyBox<T: Sendable>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<T, DecoderError>?

    func complete(_ value: Result<T, DecoderError>) {
        lock.lock()
        let first = result == nil
        if first {
            result = value
        }
        lock.unlock()
        if first {
            semaphore.signal()
        }
    }

    func wait(timeout: TimeInterval) -> Result<T, DecoderError>? {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
