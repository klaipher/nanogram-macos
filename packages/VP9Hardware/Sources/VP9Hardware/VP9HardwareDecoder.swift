import Foundation
public import CoreVideo
import CoreMedia
import VideoToolbox

// What the device reports about hardware VP9 decoding. Nothing in it is user data.
public struct VP9HardwareProbeResult: Sendable, Equatable, CustomStringConvertible {
    // VTRegisterSupplementalVideoDecoderIfAvailable exists (iOS 26.2+, macOS 11+) and was called.
    public let didRequestSupplementalDecoder: Bool
    public let isHardwareDecodeSupported: Bool
    // OSStatus of creating a session that requires a hardware decoder; nil when not tried.
    public let sessionStatus: Int32?
    public let usesHardwareDecoder: Bool

    public init(didRequestSupplementalDecoder: Bool, isHardwareDecodeSupported: Bool, sessionStatus: Int32?, usesHardwareDecoder: Bool) {
        self.didRequestSupplementalDecoder = didRequestSupplementalDecoder
        self.isHardwareDecodeSupported = isHardwareDecodeSupported
        self.sessionStatus = sessionStatus
        self.usesHardwareDecoder = usesHardwareDecoder
    }

    public var hasHardwareDecoder: Bool {
        return self.isHardwareDecodeSupported && self.sessionStatus == 0 && self.usesHardwareDecoder
    }

    public var description: String {
        let status = self.sessionStatus.map { "\($0)" } ?? "not tried"
        return "VP9 hardware decode: requested=\(self.didRequestSupplementalDecoder) supported=\(self.isHardwareDecodeSupported) session=\(status) usingHardware=\(self.usesHardwareDecoder) -> \(self.hasHardwareDecoder ? "hardware" : "libvpx")"
    }
}

public enum VP9HardwareDecoding {
    // Registers the system VP9 decoder where the OS offers it and checks that a session
    // really runs on hardware. Call once; the registration is process-wide.
    public static func probe() -> VP9HardwareProbeResult {
        // Before iOS 26.2 apps cannot opt in to the supplemental VP9 decoder.
        guard #available(iOS 26.2, macOS 11.0, tvOS 26.2, visionOS 26.2, *) else {
            return VP9HardwareProbeResult(didRequestSupplementalDecoder: false, isHardwareDecodeSupported: false, sessionStatus: nil, usesHardwareDecoder: false)
        }
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        let didRequest = true
        let isSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
        guard isSupported else {
            return VP9HardwareProbeResult(didRequestSupplementalDecoder: didRequest, isHardwareDecodeSupported: false, sessionStatus: nil, usesHardwareDecoder: false)
        }
        guard let formatDescription = vp9FormatDescription(width: 512, height: 512, fullRange: false) else {
            return VP9HardwareProbeResult(didRequestSupplementalDecoder: didRequest, isHardwareDecodeSupported: true, sessionStatus: nil, usesHardwareDecoder: false)
        }
        let (status, session) = makeSession(formatDescription: formatDescription)
        var usesHardware = false
        if let session {
            usesHardware = sessionUsesHardware(session)
            VTDecompressionSessionInvalidate(session)
        }
        return VP9HardwareProbeResult(didRequestSupplementalDecoder: didRequest, isHardwareDecodeSupported: true, sessionStatus: status, usesHardwareDecoder: usesHardware)
    }

    // Hardware sessions are a limited resource; more stickers than this decode with libvpx.
    public static let maxConcurrentSessions = 8
    private static let sessionCount = SessionCounter()

    final class SessionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func acquire(_ count: Int, limit: Int) -> Bool {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            if self.value + count > limit {
                return false
            }
            self.value += count
            return true
        }

        func release(_ count: Int) {
            self.lock.lock()
            self.value -= count
            self.lock.unlock()
        }

        var current: Int {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.value
        }
    }

    static func acquireSessions(_ count: Int) -> Bool {
        return self.sessionCount.acquire(count, limit: self.maxConcurrentSessions)
    }

    static func releaseSessions(_ count: Int) {
        self.sessionCount.release(count)
    }

    public static var activeSessionCount: Int {
        return self.sessionCount.current
    }

    // VPCodecConfigurationRecord: profile 0, level 3.1, 8 bit, 4:2:0, BT.709 colour description.
    static func vp9FormatDescription(width: Int, height: Int, fullRange: Bool) -> CMVideoFormatDescription? {
        // bitDepth 8 << 4 | chromaSubsampling 1 << 1 | fullRange
        let depthChromaRange: UInt8 = 0x82 | (fullRange ? 1 : 0)
        let vpcC: [UInt8] = [1, 0, 0, 0, 0, 31, depthChromaRange, 1, 1, 1, 0, 0]
        let extensions: NSDictionary = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["vpcC": Data(vpcC)] as NSDictionary
        ]
        guard let width = Int32(exactly: width), let height = Int32(exactly: height) else {
            return nil
        }
        var formatDescription: CMVideoFormatDescription?
        let status = unsafe CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_VP9, width: width, height: height, extensions: extensions, formatDescriptionOut: &formatDescription)
        if status != noErr {
            return nil
        }
        return formatDescription
    }

    @available(iOS 26.2, macOS 11.0, tvOS 26.2, visionOS 26.2, *)
    static func makeSession(formatDescription: CMVideoFormatDescription) -> (OSStatus, VTDecompressionSession?) {
        let specification: NSDictionary = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
        ]
        let attributes: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()
        ]
        var session: VTDecompressionSession?
        let status = unsafe VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: formatDescription, decoderSpecification: specification, imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
        if status != noErr {
            return (status, nil)
        }
        return (status, session)
    }

    @available(iOS 26.2, macOS 11.0, tvOS 26.2, visionOS 26.2, *)
    static func sessionUsesHardware(_ session: VTDecompressionSession) -> Bool {
        // The property is returned retained ("Copy").
        var value: Unmanaged<CFTypeRef>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            return unsafe VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: kCFAllocatorDefault, valueOut: UnsafeMutableRawPointer(pointer))
        }
        guard status == noErr, let object = unsafe value?.takeRetainedValue() else {
            return false
        }
        return (object as? Bool) ?? false
    }
}

// A decoded frame: 8-bit 4:2:0 video range colour, and for stickers with transparency the
// alpha stream, whose luma is the alpha.
public struct VP9DecodedFrame {
    public let color: CVPixelBuffer
    public let alpha: CVPixelBuffer?

    public init(color: CVPixelBuffer, alpha: CVPixelBuffer?) {
        self.color = color
        self.alpha = alpha
    }
}

// Decodes the frames of one sticker with hardware VP9 sessions. Not thread safe: use it from
// one queue, like the FFmpeg reader it stands in for.
public final class VP9HardwareFrameDecoder {
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var buffer: CVPixelBuffer?
        var status: OSStatus = noErr
    }

    private let formatDescription: CMVideoFormatDescription
    private let colorSession: VTDecompressionSession
    private let alphaSession: VTDecompressionSession?
    private let sessionCount: Int
    private var isInvalidated = false

    // Nil when the sticker is not plain 8-bit 4:2:0 VP9, or no hardware session can be made.
    public init?(sticker: WebMSticker) {
        guard #available(iOS 26.2, macOS 11.0, tvOS 26.2, visionOS 26.2, *) else {
            return nil
        }
        guard let first = sticker.frames.first, let colorRange = VP9HardwareFrameDecoder.keyFrameColorRange(first.color) else {
            return nil
        }
        // Output is requested as video range, and only video-range files were checked against libvpx.
        // A full-range file could come back range-converted (alpha 255 -> 235), so it stays on libvpx.
        if colorRange {
            return nil
        }
        if let alpha = first.alpha, VP9HardwareFrameDecoder.keyFrameColorRange(alpha) != false {
            return nil
        }
        guard let formatDescription = VP9HardwareDecoding.vp9FormatDescription(width: sticker.width, height: sticker.height, fullRange: colorRange) else {
            return nil
        }
        let hasAlpha = sticker.hasAlpha
        let sessionCount = hasAlpha ? 2 : 1
        guard VP9HardwareDecoding.acquireSessions(sessionCount) else {
            return nil
        }
        let (_, colorSession) = VP9HardwareDecoding.makeSession(formatDescription: formatDescription)
        guard let colorSession, VP9HardwareDecoding.sessionUsesHardware(colorSession) else {
            if let colorSession {
                VTDecompressionSessionInvalidate(colorSession)
            }
            VP9HardwareDecoding.releaseSessions(sessionCount)
            return nil
        }
        var alphaSession: VTDecompressionSession?
        if hasAlpha {
            let (_, session) = VP9HardwareDecoding.makeSession(formatDescription: formatDescription)
            guard let session, VP9HardwareDecoding.sessionUsesHardware(session) else {
                if let session {
                    VTDecompressionSessionInvalidate(session)
                }
                VTDecompressionSessionInvalidate(colorSession)
                VP9HardwareDecoding.releaseSessions(sessionCount)
                return nil
            }
            alphaSession = session
        }
        self.formatDescription = formatDescription
        self.colorSession = colorSession
        self.alphaSession = alphaSession
        self.sessionCount = sessionCount
    }

    deinit {
        self.invalidate()
    }

    public func invalidate() {
        if self.isInvalidated {
            return
        }
        self.isInvalidated = true
        VTDecompressionSessionInvalidate(self.colorSession)
        if let alphaSession = self.alphaSession {
            VTDecompressionSessionInvalidate(alphaSession)
        }
        VP9HardwareDecoding.releaseSessions(self.sessionCount)
    }

    // Frames must be passed in order, starting from a key frame. Nil on any decoder error.
    public func decode(_ frame: WebMStickerFrame) -> VP9DecodedFrame? {
        if self.isInvalidated {
            return nil
        }
        guard let color = self.decode(packet: frame.color, session: self.colorSession) else {
            return nil
        }
        var alpha: CVPixelBuffer?
        if let alphaSession = self.alphaSession {
            // A frame without alpha data in a sticker that has it cannot be shown correctly.
            guard let alphaPacket = frame.alpha, let decoded = self.decode(packet: alphaPacket, session: alphaSession) else {
                return nil
            }
            alpha = decoded
        }
        return VP9DecodedFrame(color: color, alpha: alpha)
    }

    // Finishes pending frames before decoding starts again from the first frame, which is a
    // key frame (checked in init), so no earlier reference frame is used.
    public func reset() {
        VTDecompressionSessionWaitForAsynchronousFrames(self.colorSession)
        if let alphaSession = self.alphaSession {
            VTDecompressionSessionWaitForAsynchronousFrames(alphaSession)
        }
    }

    private func decode(packet: Data, session: VTDecompressionSession) -> CVPixelBuffer? {
        guard !packet.isEmpty, let sampleBuffer = self.makeSampleBuffer(packet) else {
            return nil
        }
        let output = Output()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil, outputHandler: { status, _, imageBuffer, _, _ in
            output.lock.lock()
            output.status = status
            output.buffer = imageBuffer
            output.lock.unlock()
        })
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if status != noErr {
            return nil
        }
        output.lock.lock()
        defer {
            output.lock.unlock()
        }
        if output.status != noErr {
            return nil
        }
        guard let buffer = output.buffer, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            return nil
        }
        return buffer
    }

    private func makeSampleBuffer(_ packet: Data) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let length = packet.count
        var status = unsafe CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else {
            return nil
        }
        status = unsafe packet.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return -1
            }
            return unsafe CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: length)
        }
        guard status == noErr else {
            return nil
        }
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        status = unsafe CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: self.formatDescription, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        guard status == noErr else {
            return nil
        }
        return sampleBuffer
    }

    // The colour range of a profile 0 key frame; nil for anything else (other profiles,
    // RGB, a frame that is not a key frame).
    static func keyFrameColorRange(_ data: Data) -> Bool? {
        guard data.count >= 5, WebMStickerDemuxer.isVP9KeyFrame(data) else {
            return nil
        }
        let bytes = [UInt8](data.prefix(5))
        // frame_marker(2) profile(2) show_existing_frame(1) frame_type(1) show_frame(1) error_resilient_mode(1)
        let profile = Int((bytes[0] >> 5) & 1) | (Int((bytes[0] >> 4) & 1) << 1)
        guard profile == 0 else {
            return nil
        }
        // frame_sync_code
        guard bytes[1] == 0x49, bytes[2] == 0x83, bytes[3] == 0x42 else {
            return nil
        }
        // color_space(3) color_range(1); profile 0 is always 4:2:0.
        let colorSpace = bytes[4] >> 5
        if colorSpace == 7 {
            return nil
        }
        return (bytes[4] >> 4) & 1 == 1
    }
}
