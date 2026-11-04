import Foundation

public struct IsolatedDecoderBackend: Sendable {
    public let client: DecoderXPCClient

    public init(client: DecoderXPCClient) {
        self.client = client
    }

    public func makeAnimation(json: Data, preferTLottie: Bool, fallback: @escaping () -> AnimationRendering?) -> AnimationRendering? {
        guard client.isAvailable, json.count <= client.configuration.limits.maxAnimationBytes else {
            return fallback()
        }
        guard let opened = try? client.openAnimation(json, preferTLottie: preferTLottie) else {
            return fallback()
        }
        return IsolatedAnimationRenderer(client: client, opened: opened, fallbackFactory: fallback)
    }

    public func decodeImage(_ data: Data, maxPixelSize: Int, fallback: () -> DecodedBitmap?) -> DecodedBitmap? {
        guard client.isAvailable, let bitmap = try? client.decodeImage(data, maxPixelSize: maxPixelSize) else {
            return fallback()
        }
        return bitmap
    }
}

final class IsolatedAnimationRenderer: AnimationRendering, @unchecked Sendable {
    let startFrame: Int32
    let endFrame: Int32
    let fps: Int32

    private let client: DecoderXPCClient
    private let session: Int64
    private let fallbackFactory: () -> AnimationRendering?
    private let lock = NSLock()
    private var colors: [(DecoderColor, String)] = []
    private var fallback: AnimationRendering?
    private var usesService = true

    init(client: DecoderXPCClient, opened: DecoderXPCClient.OpenedAnimation, fallbackFactory: @escaping () -> AnimationRendering?) {
        self.client = client
        self.session = opened.session
        self.startFrame = opened.startFrame
        self.endFrame = opened.endFrame
        self.fps = opened.fps
        self.fallbackFactory = fallbackFactory
    }

    func renderFrame(_ index: Int32, into buffer: UnsafeMutablePointer<UInt8>, width: Int32, height: Int32, bytesPerRow: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if usesService {
            do {
                let frame = try client.renderFrame(session: session, index: index, width: Int(width), height: Int(height), bytesPerRow: Int(bytesPerRow))
                frame.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        memcpy(buffer, base, raw.count)
                    }
                }
                return
            } catch {
                usesService = false
            }
        }
        if fallback == nil, let made = fallbackFactory() {
            for (color, keyPath) in colors {
                made.setColor(color, keyPath: keyPath)
            }
            fallback = made
        }
        if let fallback {
            fallback.renderFrame(index, into: buffer, width: width, height: height, bytesPerRow: bytesPerRow)
        } else {
            memset(buffer, 0, Int(height) * Int(bytesPerRow))
        }
    }

    func setColor(_ color: DecoderColor, keyPath: String) {
        lock.lock()
        defer { lock.unlock() }
        colors.append((color, keyPath))
        if usesService {
            client.setColor(session: session, color: color, keyPath: keyPath)
        }
        fallback?.setColor(color, keyPath: keyPath)
    }

    deinit {
        if usesService {
            client.closeAnimation(session: session)
        }
    }
}
