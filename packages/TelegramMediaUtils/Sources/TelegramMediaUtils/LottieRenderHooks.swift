import Foundation
import CoreGraphics

public protocol LottieFrameRenderer: AnyObject {
    func renderFrame(with index: Int32, into buffer: UnsafeMutablePointer<UInt8>, width: Int32, height: Int32, bytesPerRow: Int32)
    func endFrame() -> Int32
}

public struct LottieRenderHooks {
    public let makeRenderer: (String, String) -> LottieFrameRenderer?

    public init(makeRenderer: @escaping (String, String) -> LottieFrameRenderer?) {
        self.makeRenderer = makeRenderer
    }

    private static var installed: LottieRenderHooks?

    public static var shared: LottieRenderHooks {
        guard let hooks = installed else {
            fatalError("LottieRenderHooks.install must be called before lottie rendering is used")
        }
        return hooks
    }

    public static func install(_ hooks: LottieRenderHooks) {
        installed = hooks
    }
}

public enum StickerImageDecodeResult {
    case image(CGImage)
    case refused
    case notHandled
}

public struct StickerImageDecodeHooks {
    public let decodeFitting: (Data, CGSize) -> StickerImageDecodeResult

    public init(decodeFitting: @escaping (Data, CGSize) -> StickerImageDecodeResult) {
        self.decodeFitting = decodeFitting
    }

    public nonisolated(unsafe) private(set) static var installed: StickerImageDecodeHooks?

    public static func install(_ hooks: StickerImageDecodeHooks?) {
        installed = hooks
    }
}
