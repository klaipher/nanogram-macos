import Foundation

public struct DecoderColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public protocol AnimationRendering: AnyObject {
    var startFrame: Int32 { get }
    var endFrame: Int32 { get }
    var fps: Int32 { get }
    func renderFrame(_ index: Int32, into buffer: UnsafeMutablePointer<UInt8>, width: Int32, height: Int32, bytesPerRow: Int32)
    func setColor(_ color: DecoderColor, keyPath: String)
}

public struct DecodedBitmap: Equatable, Sendable {
    public let pixels: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(pixels: Data, width: Int, height: Int, bytesPerRow: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }
}

public enum DecoderError: String, Error, Equatable, Sendable {
    case inputTooLarge
    case invalidDimensions
    case tooManySessions
    case unknownSession
    case rendererUnavailable
    case decodeFailed
    case timedOut
    case connectionLost
    case badReply
    case serviceUnavailable
    case staleSession

    var countsAsServiceFailure: Bool {
        switch self {
        case .timedOut, .connectionLost, .badReply, .serviceUnavailable:
            return true
        case .inputTooLarge, .invalidDimensions, .tooManySessions, .unknownSession, .rendererUnavailable, .decodeFailed, .staleSession:
            return false
        }
    }
}

public struct DecoderLimits: Equatable, Sendable {
    public var maxAnimationBytes: Int
    public var maxFrameDimension: Int
    public var maxFrameBytes: Int
    public var maxSessionsPerConnection: Int
    public var maxImageBytes: Int
    public var maxSourcePixels: Int

    public init(maxAnimationBytes: Int = 8 * 1024 * 1024, maxFrameDimension: Int = 4096, maxFrameBytes: Int = 64 * 1024 * 1024, maxSessionsPerConnection: Int = 512, maxImageBytes: Int = 8 * 1024 * 1024, maxSourcePixels: Int = 36 * 1024 * 1024) {
        self.maxAnimationBytes = maxAnimationBytes
        self.maxFrameDimension = maxFrameDimension
        self.maxFrameBytes = maxFrameBytes
        self.maxSessionsPerConnection = maxSessionsPerConnection
        self.maxImageBytes = maxImageBytes
        self.maxSourcePixels = maxSourcePixels
    }

    public static let standard = DecoderLimits()
}

@objc public protocol NanogramDecoderXPCProtocol {
    func openAnimation(_ data: Data, preferTLottie: Bool, reply: @escaping @Sendable (Int64, Int32, Int32, Int32, String?) -> Void)
    func renderFrame(session: Int64, index: Int32, width: Int32, height: Int32, bytesPerRow: Int32, reply: @escaping @Sendable (Data?, String?) -> Void)
    func setColor(session: Int64, red: Double, green: Double, blue: Double, alpha: Double, keyPath: String)
    func closeAnimation(session: Int64)
    func decodeImage(_ data: Data, maxPixelSize: Int32, reply: @escaping @Sendable (Data?, Int32, Int32, Int32, String?) -> Void)
}

public enum DecoderService {
    public static let machServiceName = "org.klaipher.Nanogram.Decoder"
}
