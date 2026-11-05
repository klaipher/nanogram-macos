import Foundation
public import CoreVideo
import CoreMedia
import VideoToolbox
import os

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

// How the stickers that asked for a hardware decoder fared. The session cap (`maxConcurrentSessions`) leaves libvpx
// for every sticker after the first four with alpha; these counters show whether that is what happens.
public struct VP9HardwareStats: Sendable, Equatable {
    // A sticker got a hardware decoder.
    public var hardwareStarts = 0
    // No decoder: every session slot was taken.
    public var capMisses = 0
    // No decoder: a hardware session could not be created, or did not run on hardware.
    public var sessionFailures = 0
    // No decoder: not a plain 8-bit video-range 4:2:0 VP9 file.
    public var ineligible = 0
    // The most session slots in use at once.
    public var peakSessions = 0

    public init(hardwareStarts: Int = 0, capMisses: Int = 0, sessionFailures: Int = 0, ineligible: Int = 0, peakSessions: Int = 0) {
        self.hardwareStarts = hardwareStarts
        self.capMisses = capMisses
        self.sessionFailures = sessionFailures
        self.ineligible = ineligible
        self.peakSessions = peakSessions
    }

    public var description: String {
        return "VP9 hardware stickers: hardwareStarts=\(self.hardwareStarts) capMisses=\(self.capMisses) sessionFailures=\(self.sessionFailures) ineligible=\(self.ineligible) peakSessions=\(self.peakSessions)"
    }
}

enum VP9HardwareOutcome {
    case hardware
    case capReached
    case sessionFailure
    case ineligible
}

final class VP9HardwareStatsStore: @unchecked Sendable {
    static let reportInterval: Double = 60.0

    private let lock = NSLock()
    private var stats = VP9HardwareStats()
    private var reportedStats = VP9HardwareStats()
    private var lastReportTime: Double?
    private var reporter: (@Sendable (String) -> Void)?

    var snapshot: VP9HardwareStats {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.stats
    }

    func record(_ outcome: VP9HardwareOutcome) {
        self.lock.lock()
        switch outcome {
        case .hardware:
            self.stats.hardwareStarts += 1
        case .capReached:
            self.stats.capMisses += 1
        case .sessionFailure:
            self.stats.sessionFailures += 1
        case .ineligible:
            self.stats.ineligible += 1
        }
        self.lock.unlock()
    }

    func noteActiveSessions(_ count: Int) {
        self.lock.lock()
        if count > self.stats.peakSessions {
            self.stats.peakSessions = count
        }
        self.lock.unlock()
    }

    func setReporter(_ reporter: (@Sendable (String) -> Void)?) {
        self.lock.lock()
        self.reporter = reporter
        self.lock.unlock()
    }

    // The text to log when a minute passed since the last report and the counters changed since then.
    func takeReport(now: Double) -> String? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.stats == self.reportedStats {
            return nil
        }
        if let lastReportTime = self.lastReportTime {
            let elapsed = now - lastReportTime
            // A clock set backwards must not silence the report for good.
            if elapsed >= 0.0 && elapsed < VP9HardwareStatsStore.reportInterval {
                return nil
            }
        }
        self.lastReportTime = now
        self.reportedStats = self.stats
        return self.stats.description
    }

    func reportIfDue(now: Double) {
        self.lock.lock()
        let reporter = self.reporter
        self.lock.unlock()
        guard let reporter, let text = self.takeReport(now: now) else {
            return
        }
        reporter(text)
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
    static let statsStore = VP9HardwareStatsStore()
    @available(macOS 12.0, iOS 15.0, *)
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "VP9Hardware", category: "Performance")

    public static var stats: VP9HardwareStats {
        return self.statsStore.snapshot
    }

    // Called with the counters at most once a minute, and only when they changed. The app logs it.
    public static func setStatsReporter(_ reporter: (@Sendable (String) -> Void)?) {
        self.statsStore.setReporter(reporter)
    }

    // A sticker that wanted hardware decoding and did not get it leaves a signpost event, so a trace shows where.
    static func record(_ outcome: VP9HardwareOutcome) {
        self.statsStore.record(outcome)
        if #available(macOS 12.0, iOS 15.0, *) {
            switch outcome {
            case .capReached:
                self.signposter.emitEvent("vp9HardwareCapReached")
            case .sessionFailure:
                self.signposter.emitEvent("vp9HardwareSessionFailure")
            case .hardware, .ineligible:
                break
            }
        }
        self.statsStore.reportIfDue(now: Date().timeIntervalSince1970)
    }

    final class SessionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var peakValue = 0

        func acquire(_ count: Int, limit: Int) -> Bool {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            if self.value + count > limit {
                return false
            }
            self.value += count
            self.peakValue = max(self.peakValue, self.value)
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

        var peak: Int {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.peakValue
        }
    }

    static func acquireSessions(_ count: Int) -> Bool {
        let didAcquire = self.sessionCount.acquire(count, limit: self.maxConcurrentSessions)
        if didAcquire {
            self.statsStore.noteActiveSessions(self.sessionCount.peak)
        }
        return didAcquire
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
            VP9HardwareDecoding.record(.ineligible)
            return nil
        }
        // Output is requested as video range, and only video-range files were checked against libvpx.
        // A full-range file could come back range-converted (alpha 255 -> 235), so it stays on libvpx.
        if colorRange {
            VP9HardwareDecoding.record(.ineligible)
            return nil
        }
        if let alpha = first.alpha, VP9HardwareFrameDecoder.keyFrameColorRange(alpha) != false {
            VP9HardwareDecoding.record(.ineligible)
            return nil
        }
        guard let formatDescription = VP9HardwareDecoding.vp9FormatDescription(width: sticker.width, height: sticker.height, fullRange: colorRange) else {
            VP9HardwareDecoding.record(.ineligible)
            return nil
        }
        let hasAlpha = sticker.hasAlpha
        let sessionCount = hasAlpha ? 2 : 1
        guard VP9HardwareDecoding.acquireSessions(sessionCount) else {
            VP9HardwareDecoding.record(.capReached)
            return nil
        }
        let (_, colorSession) = VP9HardwareDecoding.makeSession(formatDescription: formatDescription)
        guard let colorSession, VP9HardwareDecoding.sessionUsesHardware(colorSession) else {
            if let colorSession {
                VTDecompressionSessionInvalidate(colorSession)
            }
            VP9HardwareDecoding.releaseSessions(sessionCount)
            VP9HardwareDecoding.record(.sessionFailure)
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
                VP9HardwareDecoding.record(.sessionFailure)
                return nil
            }
            alphaSession = session
        }
        self.formatDescription = formatDescription
        self.colorSession = colorSession
        self.alphaSession = alphaSession
        self.sessionCount = sessionCount
        VP9HardwareDecoding.record(.hardware)
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
