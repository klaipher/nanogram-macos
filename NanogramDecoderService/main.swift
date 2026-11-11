import AppKit
import NanogramDecoder
import TLottie

private final class TLottieAnimation: AnimationRendering {
    private let bridge: TLottieBridge

    init(bridge: TLottieBridge) {
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

let limits = DecoderLimits.standard

DecoderListenerDelegate(
    limits: limits,
    makeAnimation: { data, _ in
        guard let json = String(data: data, encoding: .utf8), !json.isEmpty, let bridge = TLottieBridge(json: json) else {
            return nil
        }
        return TLottieAnimation(bridge: bridge)
    },
    decodeImage: { data, maxPixelSize in
        return try ImageIODecoder.decode(data, maxPixelSize: maxPixelSize, limits: limits)
    }
).run()
