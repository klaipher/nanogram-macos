import Foundation

public final class DecoderConnectionService: NSObject, NanogramDecoderXPCProtocol, @unchecked Sendable {
    public typealias AnimationFactory = @Sendable (Data, Bool) -> AnimationRendering?
    public typealias ImageDecoder = @Sendable (Data, Int) throws -> DecodedBitmap

    private let limits: DecoderLimits
    private let makeAnimation: AnimationFactory
    private let imageDecoder: ImageDecoder
    private let lock = NSLock()
    private var sessions: [Int64: AnimationRendering] = [:]
    private var nextSession: Int64 = 1

    public init(limits: DecoderLimits, makeAnimation: @escaping AnimationFactory, decodeImage: @escaping ImageDecoder) {
        self.limits = limits
        self.makeAnimation = makeAnimation
        self.imageDecoder = decodeImage
    }

    public func openAnimation(_ data: Data, preferTLottie: Bool, reply: @escaping @Sendable (Int64, Int32, Int32, Int32, String?) -> Void) {
        guard data.count <= limits.maxAnimationBytes else {
            reply(0, 0, 0, 0, DecoderError.inputTooLarge.rawValue)
            return
        }
        lock.lock()
        let full = sessions.count >= limits.maxSessionsPerConnection
        lock.unlock()
        guard !full else {
            reply(0, 0, 0, 0, DecoderError.tooManySessions.rawValue)
            return
        }
        guard let animation = makeAnimation(data, preferTLottie) else {
            reply(0, 0, 0, 0, DecoderError.rendererUnavailable.rawValue)
            return
        }
        lock.lock()
        let session = nextSession
        nextSession += 1
        sessions[session] = animation
        lock.unlock()
        reply(session, animation.startFrame, animation.endFrame, animation.fps, nil)
    }

    public func renderFrame(session: Int64, index: Int32, width: Int32, height: Int32, bytesPerRow: Int32, reply: @escaping @Sendable (Data?, String?) -> Void) {
        let dimension = limits.maxFrameDimension
        guard width > 0, height > 0, Int(width) <= dimension, Int(height) <= dimension, Int(bytesPerRow) >= Int(width) * 4 else {
            reply(nil, DecoderError.invalidDimensions.rawValue)
            return
        }
        let total = Int(height) * Int(bytesPerRow)
        guard total <= limits.maxFrameBytes else {
            reply(nil, DecoderError.invalidDimensions.rawValue)
            return
        }
        lock.lock()
        let animation = sessions[session]
        lock.unlock()
        guard let animation else {
            reply(nil, DecoderError.unknownSession.rawValue)
            return
        }
        var frame = Data(count: total)
        frame.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                animation.renderFrame(index, into: base, width: width, height: height, bytesPerRow: bytesPerRow)
            }
        }
        reply(frame, nil)
    }

    public func setColor(session: Int64, red: Double, green: Double, blue: Double, alpha: Double, keyPath: String) {
        lock.lock()
        let animation = sessions[session]
        lock.unlock()
        animation?.setColor(DecoderColor(red: red, green: green, blue: blue, alpha: alpha), keyPath: keyPath)
    }

    public func closeAnimation(session: Int64) {
        lock.lock()
        sessions[session] = nil
        lock.unlock()
    }

    public func decodeImage(_ data: Data, maxPixelSize: Int32, reply: @escaping @Sendable (Data?, Int32, Int32, Int32, String?) -> Void) {
        guard data.count <= limits.maxImageBytes else {
            reply(nil, 0, 0, 0, DecoderError.inputTooLarge.rawValue)
            return
        }
        do {
            let bitmap = try imageDecoder(data, Int(maxPixelSize))
            reply(bitmap.pixels, Int32(clamping: bitmap.width), Int32(clamping: bitmap.height), Int32(clamping: bitmap.bytesPerRow), nil)
        } catch let error as DecoderError {
            reply(nil, 0, 0, 0, error.rawValue)
        } catch {
            reply(nil, 0, 0, 0, DecoderError.decodeFailed.rawValue)
        }
    }
}

public final class DecoderListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let limits: DecoderLimits
    private let makeAnimation: DecoderConnectionService.AnimationFactory
    private let imageDecoder: DecoderConnectionService.ImageDecoder
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []

    public init(limits: DecoderLimits, makeAnimation: @escaping DecoderConnectionService.AnimationFactory, decodeImage: @escaping DecoderConnectionService.ImageDecoder) {
        self.limits = limits
        self.makeAnimation = makeAnimation
        self.imageDecoder = decodeImage
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: NanogramDecoderXPCProtocol.self)
        newConnection.exportedObject = DecoderConnectionService(limits: limits, makeAnimation: makeAnimation, decodeImage: imageDecoder)
        lock.lock()
        connections.append(newConnection)
        lock.unlock()
        newConnection.resume()
        return true
    }

    public func invalidateAllConnections() {
        lock.lock()
        let current = connections
        connections = []
        lock.unlock()
        for connection in current {
            connection.invalidate()
        }
    }

    public func run() -> Never {
        let listener = NSXPCListener.service()
        listener.delegate = self
        listener.resume()
        fatalError("NSXPCListener.resume returned in an XPC service")
    }
}
