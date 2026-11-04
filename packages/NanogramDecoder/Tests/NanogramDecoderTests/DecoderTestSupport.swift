import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import NanogramDecoder

final class FakeAnimation: AnimationRendering, @unchecked Sendable {
    let json: Data
    let startFrame: Int32 = 0
    let endFrame: Int32 = 60
    let fps: Int32 = 30
    private let lock = NSLock()
    private(set) var colors: [String] = []
    var hook: (@Sendable () -> (@Sendable (Int32) -> Void)?)?

    init(json: Data) {
        self.json = json
    }

    func renderFrame(_ index: Int32, into buffer: UnsafeMutablePointer<UInt8>, width: Int32, height: Int32, bytesPerRow: Int32) {
        hook?()?(index)
        let value = UInt8(truncatingIfNeeded: Int(index) &+ json.count)
        for row in 0..<Int(height) {
            let line = buffer.advanced(by: row * Int(bytesPerRow))
            memset(line, Int32(value), Int(width) * 4)
        }
    }

    func setColor(_ color: DecoderColor, keyPath: String) {
        lock.lock()
        colors.append("\(keyPath):\(color.red),\(color.green),\(color.blue),\(color.alpha)")
        lock.unlock()
    }
}

final class FakeAnimations: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var created: [FakeAnimation] = []
    private var storedOnRender: (@Sendable (Int32) -> Void)?
    var rejectsEverything = false

    var onRender: (@Sendable (Int32) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedOnRender
        }
        set {
            lock.lock()
            storedOnRender = newValue
            lock.unlock()
        }
    }

    func make(json: Data, preferTLottie: Bool) -> AnimationRendering? {
        if rejectsEverything {
            return nil
        }
        let animation = FakeAnimation(json: json)
        animation.hook = { [unowned self] in self.onRender }
        lock.lock()
        created.append(animation)
        lock.unlock()
        return animation
    }
}

final class TestService: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let delegate: DecoderListenerDelegate
    let animations = FakeAnimations()
    private let lock = NSLock()
    private var serverConnections: [NSXPCConnection] = []

    init(limits: DecoderLimits = .standard) {
        let animations = animations
        delegate = DecoderListenerDelegate(
            limits: limits,
            makeAnimation: { json, preferTLottie in animations.make(json: json, preferTLottie: preferTLottie) },
            decodeImage: { data, maxPixelSize in try ImageIODecoder.decode(data, maxPixelSize: maxPixelSize, limits: limits) })
        listener.delegate = delegate
        listener.resume()
    }

    func makeClient(configuration: DecoderXPCClient.Configuration = .init()) -> DecoderXPCClient {
        let endpoint = listener.endpoint
        return DecoderXPCClient(configuration: configuration, makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) })
    }

    func dropAllConnections() {
        delegate.invalidateAllConnections()
    }

    deinit {
        listener.invalidate()
    }
}

func samplePNG(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}
