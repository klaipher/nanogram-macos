import Foundation
import VideoToolbox
import CoreMedia
import QuartzCore

let width = 1280, height = 720, fps = 25, seconds = 60
func targetKbps(_ t: Double) -> Int { t < 20 ? 1000 : (t < 40 ? 300 : 800) }

final class Stats { var bytes: [Int] = Array(repeating: 0, count: 60); var latencies: [Double] = []; var keyframes = 0; let lock = NSLock() }

func run(name: String, realTime: Bool, lowLatency: Bool) {
    var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
    if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
    let stats = Stats()
    var session: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard st == noErr, let s = session else { print(name, "create failed", st); return }
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: realTime as CFBoolean)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 7200 as CFNumber)
    if realTime { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber) }
    var current = -1
    func setRate(_ kbps: Int) {
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: (kbps * 1000) as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [Int(Double(kbps * 1000) * 1.5 / 8), 1] as CFArray)
    }
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool)
    var rng = SystemRandomNumberGenerator()
    for frame in 0 ..< fps * seconds {
        let t = Double(frame) / Double(fps)
        if targetKbps(t) != current { current = targetKbps(t); setRate(current) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb!, 0)
        for row in 0 ..< height {
            let p = y.advanced(by: row * bpr)
            for col in stride(from: 0, to: width, by: 1) {
                p[col] = UInt8(truncatingIfNeeded: (col + frame * 4) ^ (row + frame * 2)) &+ (row % 64 == 0 ? UInt8.random(in: 0...255, using: &rng) : 0)
            }
        }
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb!, 1)!.assumingMemoryBound(to: UInt8.self)
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb!, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        let submit = CACurrentMediaTime()
        let second = Int(t)
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb!, presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)), duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: nil, infoFlagsOut: nil, outputHandler: { status, _, sample in
            guard let sample else { return }
            let size = CMSampleBufferGetTotalSampleSize(sample)
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
            stats.lock.lock(); stats.bytes[second] += size; stats.latencies.append(CACurrentMediaTime() - submit); if key { stats.keyframes += 1 }; stats.lock.unlock()
        })
        Thread.sleep(forTimeInterval: 0.001)
    }
    VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(s)
    let ratios = (0 ..< seconds).map { Double(stats.bytes[$0] * 8) / Double(targetKbps(Double($0)) * 1000) }
    let afterDrop = ratios[20 ..< 40]
    let lat = stats.latencies.sorted()
    print(String(format: "%@: worst 1 s window after the drop %.2fx target, mean %.2fx; seconds >1.1x after drop: %d; whole run mean %.2fx; encode latency p50 %.1f ms p95 %.1f ms; keyframes %d", name, afterDrop.max()!, afterDrop.reduce(0, +) / 20, afterDrop.filter { $0 > 1.1 }.count, ratios.reduce(0, +) / Double(seconds), lat[lat.count / 2] * 1000, lat[lat.count * 95 / 100] * 1000, stats.keyframes))
    print("  per-second ratios 18-26 s:", ratios[18...26].map { String(format: "%.2f", $0) }.joined(separator: " "))
}
run(name: "today (RealTime=false)", realTime: false, lowLatency: false)
run(name: "RealTime=true", realTime: true, lowLatency: false)
run(name: "RealTime=true + LowLatencyRateControl", realTime: true, lowLatency: true)
