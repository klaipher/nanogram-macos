import Cocoa
import RLottie
import TLottie
import TelegramMedia
import TelegramMediaUtils
import NanogramDebug
import NanogramDecoder

extension RLottieBridge: @retroactive LottieFrameRenderer {}
extension TLottieBridge: @retroactive LottieFrameRenderer {}

enum DecoderIsolation {
    static let optionId = "decoding.isolatedXPC"

    static let debugOption = NanogramDebugOption.toggle(id: optionId, section: "Security", title: "Isolated sticker decoding", detail: "Animated stickers and emoji and sticker previews are decoded in a sandboxed helper process with no network or file access. If the helper crashes or stalls, decoding continues in the app. Default: off. Applies to stickers opened after the change.", defaultValue: false)

    static var isEnabled: Bool {
        return NanogramDebugSettings.shared.bool(optionId)
    }

    static let backend = IsolatedDecoderBackend(client: DecoderXPCClient())
}

typealias LottieBridge = NSObject & R_LottieBridge & LottieFrameRenderer

private final class LegacyLottieAnimation: AnimationRendering {
    private let bridge: R_LottieBridge

    init(bridge: R_LottieBridge) {
        self.bridge = bridge
    }

    var startFrame: Int32 { return bridge.startFrame() }
    var endFrame: Int32 { return bridge.endFrame() }
    var fps: Int32 { return bridge.fps() }

    func renderFrame(_ index: Int32, into buffer: UnsafeMutablePointer<UInt8>, width: Int32, height: Int32, bytesPerRow: Int32) {
        bridge.renderFrame(with: index, into: buffer, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    func setColor(_ color: DecoderColor, keyPath: String) {
        bridge.setColor(NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha), forKeyPath: keyPath)
    }
}

final class IsolatedLottieBridge: NSObject, R_LottieBridge, LottieFrameRenderer {
    private let renderer: AnimationRendering

    init(renderer: AnimationRendering) {
        self.renderer = renderer
        super.init()
    }

    func renderFrame(with index: Int32, into buffer: UnsafeMutablePointer<UInt8>, width: Int32, height: Int32, bytesPerRow: Int32) {
        renderer.renderFrame(index, into: buffer, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    func startFrame() -> Int32 {
        return renderer.startFrame
    }

    func endFrame() -> Int32 {
        return renderer.endFrame
    }

    func fps() -> Int32 {
        return renderer.fps
    }

    func setColor(_ color: NSColor, forKeyPath keyPath: String) {
        guard let rgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) else {
            return
        }
        renderer.setColor(DecoderColor(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent)), keyPath: keyPath)
    }
}

private func makeLegacyLottieBridge(json: String, key: String) -> LottieBridge? {
    if LottieBackend.usesTLottie {
        return TLottieBridge(json: json)
    }
    return RLottieBridge(json: json, key: key)
}

func makeLottieBridge(json: String, key: String) -> LottieBridge? {
    guard DecoderIsolation.isEnabled else {
        return makeLegacyLottieBridge(json: json, key: key)
    }
    guard let data = json.data(using: .utf8) else {
        return nil
    }
    let renderer = DecoderIsolation.backend.makeAnimation(json: data, preferTLottie: LottieBackend.usesTLottie, fallback: {
        return makeLegacyLottieBridge(json: json, key: key).map { LegacyLottieAnimation(bridge: $0) }
    })
    return renderer.map { IsolatedLottieBridge(renderer: $0) }
}

private func makeCGImage(_ bitmap: DecodedBitmap) -> CGImage? {
    guard let provider = CGDataProvider(data: bitmap.pixels as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
        return nil
    }
    return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

func installLottieRenderHooks() {
    LottieRenderHooks.install(LottieRenderHooks(makeRenderer: { json, key in
        return makeLottieBridge(json: json, key: key)
    }))
    StickerImageDecodeHooks.install(StickerImageDecodeHooks(decodeFitting: { data, pixelSize in
        guard DecoderIsolation.isEnabled else {
            return .notHandled
        }
        switch DecoderIsolation.backend.decodeImage(data, maxPixelSize: Int(max(pixelSize.width, pixelSize.height))) {
        case let .decoded(bitmap):
            return makeCGImage(bitmap).map { .image($0) } ?? .refused
        case .refused:
            return .refused
        case .unavailable:
            return .notHandled
        }
    }))
}
