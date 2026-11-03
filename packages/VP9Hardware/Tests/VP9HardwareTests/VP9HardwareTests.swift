import Foundation
import CoreVideo
import XCTest
@testable import VP9Hardware

// FNV-1a over the visible pixels of a plane; `step` and `offset` pick one channel of interleaved CbCr.
private func planeHash(_ base: UnsafeRawPointer, width: Int, height: Int, stride: Int, step: Int = 1, offset: Int = 0, into value: inout UInt64) {
    let bytes = unsafe base.assumingMemoryBound(to: UInt8.self)
    for y in 0 ..< height {
        for x in 0 ..< width {
            value ^= UInt64(unsafe bytes[y * stride + x * step + offset])
            value = value &* 1099511628211
        }
    }
}

// (Y, Cb, Cr) and alpha luma hashes of every frame, decoded with libvpx (1 thread, built for macOS
// from third-party/libvpx) from the same packets. VP9 decoding is bit-exact, so hardware must match.
private let libvpxHashesSticker30fps: [(UInt64, UInt64)] = [
    (0xabeb66ad8d24c636, 0xe59193f49747b71d),
    (0xabeb66ad8d24c636, 0xe59193f49747b71d),
    (0xabeb66ad8d24c636, 0xe59193f49747b71d),
    (0xabeb66ad8d24c636, 0xe59193f49747b71d),
    (0xabeb66ad8d24c636, 0xe59193f49747b71d),
    (0xabeb66ad8d24c636, 0xe59193f49747b71d),
    (0xabeb66ad8d24c636, 0xe59193f49747b71d),
    (0xfc5e8e88b638cd7d, 0x212c4f9c574f5c2a),
    (0x293a8e10da0854d7, 0x22133d6e5eae4a84),
    (0x98e3b2553373da27, 0x8e29eafc57528b48),
    (0x2945fe187634bc88, 0xfab0c23a21da0ccf),
    (0x76eeee3f2496707f, 0x29ab07e9bcaa22f0),
    (0x571f16b267cc405e, 0x94b406dddc98dda5),
    (0x53096caf82540d63, 0x87f085f61688a8b7),
    (0xdfa507fbbe6c6bbd, 0x86e9ac36a831be95),
    (0x16297112874e341e, 0x86e9ac36a831be95),
    (0x6afbf8495ba66563, 0x3a31f19056f016ed),
    (0xdef709f503d310b8, 0x94ca5d562bfef044),
    (0x6aac7840e585c4cc, 0x60c2348308a11a5f),
    (0x2fee6c78361e3b5c, 0x8555b9efd976efe1),
    (0x0bf6585b53d51663, 0x21ed81708db00c45),
    (0x7d514fdda53fe782, 0xd38d0c76526aea3f),
    (0x6edac71e5ea9c3bb, 0x0d983c1e28d8b4e6),
    (0x5a9aa4dc3d70ca4c, 0x1323e7e61bcd2270),
]

private let libvpxHashesSticker24fps: [(UInt64, UInt64)] = [
    (0x0e41fc6a2c3ab416, 0x503a7cc539bb8372),
    (0x5e79390d1623e7c6, 0xf6220d8d679bf10e),
    (0xace9f7d9e6fc5671, 0x4ef6b11100f18a08),
    (0xaea0951e7eebc13f, 0xf4491ac1dd6a1b3a),
    (0x57c2238d3b9c8149, 0xb72db1a4caa96c5b),
    (0xcb29b936a07dd9f5, 0xd8badb9d27515164),
    (0xd90aa1968ec95fbd, 0x602fa7bb0ff6e186),
    (0xf7f4537859dce181, 0xfe72924f34f80d5a),
    (0xb75912feab9b0a68, 0xeafedf9fa9b385ce),
    (0x7704c053593ebc32, 0xad6917cc35895051),
    (0xc9dbbb0e1a2b4352, 0x65e1d9ab74df6d9d),
    (0x03091638f71cbbb2, 0x86dd3fced05c8876),
    (0xc5087ac54d67cf6a, 0x262e29a04f0286e7),
    (0x0dde67badc86559d, 0xf845ac0c0bde5341),
    (0xe42229da01dd6e10, 0x88dbdb6cad3720f7),
    (0x77327f83789a5ba8, 0x6bdfd79f49a42eeb),
    (0x6596518e8db79a2d, 0xec47e94b5d833985),
    (0x264ff064c392fa18, 0xea9bea9c38b68a8e),
    (0x2b124d36629c2f19, 0x9cb46742c2a65d93),
    (0x0947c74cac45cd7f, 0x589970620745c561),
    (0x30ee6133b3d162ca, 0x81b9b77d5ee1e3fb),
    (0xe660dfbf7caa67c8, 0x3f9545fb4936b384),
    (0x1c11ad7e74398656, 0xb18e1141d1ee235a),
    (0xaae28687e88e1c8c, 0x417a05c78a18c699),
    (0xc5194db302c1abfe, 0x085e56c59f1519cc),
    (0x4feb31ddee72498f, 0x1fc1a67a966a4852),
    (0x591b7aab61b5f7bf, 0x785e2be4df4c9838),
    (0x1d2b9f0a54f04a3d, 0x00183d1f2c688b87),
    (0x2768f14de4ea479b, 0xdf3135be991e76c3),
    (0xb681c46e22989ddb, 0x9293b2a2a74121df),
    (0xbf5509be8ff4a7df, 0xb56a5eee4bb78d30),
    (0x5569d245bd5d95fa, 0x6f3c6e4557a29830),
    (0x06ff1a458b53bd15, 0x27332a735fc45396),
    (0xc106a1bd2aec6476, 0x4ef8369519b3553e),
    (0x43229de8095d8b0e, 0x0dfe65746d4383c8),
    (0xc8a823dbb0d4f29f, 0x157dd31472db6019),
    (0x430061966a3a616f, 0xa0a3f3ea2ac9df4a),
    (0x849e8b8fed5e98e9, 0x7288843bf641f9f2),
    (0x241a808f9b8e3677, 0xc0bc748e9793e2c5),
    (0x2ff1f232f443a72e, 0x5b15867d0d8e7c2d),
    (0x16be0ed31f302796, 0xc1c9a40a6a348b87),
    (0x6717764928d3d6b5, 0x50708dc593d8b47e),
    (0x68fc72b30b5a7d45, 0x4cdd51476af7feb2),
    (0x9870f64a79c46305, 0x2ff6ffb77275afdc),
    (0x0362ef14e0ebd38d, 0x85975b6a2695b9a7),
    (0x16140cba335e0473, 0x191f71c3364573cd),
    (0x9de95208052ff805, 0x39f9ce6dc9bcdbac),
    (0xa9d5ce519b1d9079, 0x5336d5cf52db9e37),
    (0x965d05a34936841c, 0x341e1cd94ce06d52),
    (0x0ab3055322f413bb, 0xff271e80f80e44cd),
    (0xe8d2ed21d572c5ef, 0x72c0bb50326ada31),
    (0x82ea8d4beba010e7, 0x84aebb780608d8bf),
    (0x0c9a919efeab6ff0, 0x5e7eeeff43b85eb5),
    (0x0ad6e16868a2669a, 0x4d42ad982a8eedd2),
    (0xe50f313b6c1b8fb3, 0x5d9c6d15290b1fc8),
    (0xf4b8502ab9093ce4, 0x6c8b0b846c477217),
    (0x09d5d93b144f3d2f, 0x00e7248221ccae24),
    (0xd9e079827d5199d1, 0xc3876cb5fd4d17e9),
]

private func fixture(_ name: String) throws -> Data {
    let parts = name.split(separator: ".")
    if parts.count == 2, let url = Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1]), subdirectory: "Resources") {
        return try Data(contentsOf: url)
    }
    throw XCTSkip("fixture \(name) not found")
}

final class VP9HardwareTests: XCTestCase {
    func testDemuxesStickerFixtures() throws {
        let sticker = try XCTUnwrap(WebMStickerDemuxer.parse(try fixture("sticker_vp9.webm")))
        XCTAssertEqual(sticker.width, 512)
        XCTAssertEqual(sticker.height, 512)
        XCTAssertEqual(sticker.frames.count, libvpxHashesSticker30fps.count)
        XCTAssertTrue(sticker.frames.allSatisfy { $0.alpha != nil })
        XCTAssertEqual(sticker.frames.prefix(4).map(\.timestamp), [0, 33, 67, 100])
        XCTAssertTrue(WebMStickerDemuxer.isVP9KeyFrame(sticker.frames[0].color))
        XCTAssertEqual(VP9HardwareFrameDecoder.keyFrameColorRange(sticker.frames[0].color), false)

        let other = try XCTUnwrap(WebMStickerDemuxer.parse(try fixture("sticker_24fps.webm")))
        XCTAssertEqual(other.frames.count, libvpxHashesSticker24fps.count)
    }

    // Only video-range files were compared with libvpx; a full-range one stays on libvpx.
    func testFullRangeStickerGetsNoHardwareDecoder() throws {
        let probe = VP9HardwareDecoding.probe()
        try XCTSkipUnless(probe.hasHardwareDecoder, "no hardware VP9 decoder: \(probe)")
        let sticker = try XCTUnwrap(WebMStickerDemuxer.parse(try fixture("sticker_vp9.webm")))
        func fullRange(_ data: Data) -> Data {
            var bytes = [UInt8](data)
            bytes[4] |= 0x10
            return Data(bytes)
        }
        let first = sticker.frames[0]
        XCTAssertNotNil(VP9HardwareFrameDecoder(sticker: sticker))
        let colorFull = WebMSticker(width: sticker.width, height: sticker.height, defaultFrameDuration: sticker.defaultFrameDuration, duration: sticker.duration, timestampScale: sticker.timestampScale, frames: [WebMStickerFrame(timestamp: first.timestamp, color: fullRange(first.color), alpha: first.alpha)])
        XCTAssertEqual(VP9HardwareFrameDecoder.keyFrameColorRange(colorFull.frames[0].color), true)
        XCTAssertNil(VP9HardwareFrameDecoder(sticker: colorFull))
        let alphaFull = WebMSticker(width: sticker.width, height: sticker.height, defaultFrameDuration: sticker.defaultFrameDuration, duration: sticker.duration, timestampScale: sticker.timestampScale, frames: [WebMStickerFrame(timestamp: first.timestamp, color: first.color, alpha: first.alpha.map(fullRange))])
        XCTAssertNil(VP9HardwareFrameDecoder(sticker: alphaFull))
        XCTAssertEqual(VP9HardwareDecoding.activeSessionCount, 0)
    }

    // Damaged files are rejected or parsed, and never crash.
    func testDamagedFilesDoNotCrash() throws {
        let data = [UInt8](try fixture("sticker_vp9.webm"))
        for cut in stride(from: 0, to: data.count, by: 97) {
            _ = WebMStickerDemuxer.parse(Data(data.prefix(cut)))
        }
        var state: UInt64 = 7
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        for _ in 0 ..< 3000 {
            var mutated = data
            for _ in 0 ..< 1 + next() % 12 {
                let index = next() % mutated.count
                mutated[index] = UInt8(truncatingIfNeeded: next())
            }
            if let sticker = WebMStickerDemuxer.parse(Data(mutated)) {
                XCTAssertGreaterThan(sticker.width, 0)
                XCTAssertLessThanOrEqual(sticker.frames.count, WebMStickerDemuxer.maxFrameCount)
            }
        }
        for size in [0, 1, 4, 8, 64] {
            XCTAssertNil(WebMStickerDemuxer.parse(Data(repeating: 0xff, count: size)))
            XCTAssertNil(WebMStickerDemuxer.parse(Data(repeating: 0x00, count: size)))
        }
    }

    func testProbeResultNeedsAHardwareSession() {
        let result = VP9HardwareProbeResult(didRequestSupplementalDecoder: true, isHardwareDecodeSupported: true, sessionStatus: 0, usesHardwareDecoder: true)
        XCTAssertTrue(result.hasHardwareDecoder)
        XCTAssertTrue(result.description.hasSuffix("-> hardware"))
        XCTAssertFalse(VP9HardwareProbeResult(didRequestSupplementalDecoder: true, isHardwareDecodeSupported: true, sessionStatus: 0, usesHardwareDecoder: false).hasHardwareDecoder)
        XCTAssertFalse(VP9HardwareProbeResult(didRequestSupplementalDecoder: true, isHardwareDecodeSupported: true, sessionStatus: -12906, usesHardwareDecoder: false).hasHardwareDecoder)
        XCTAssertFalse(VP9HardwareProbeResult(didRequestSupplementalDecoder: false, isHardwareDecodeSupported: false, sessionStatus: nil, usesHardwareDecoder: false).hasHardwareDecoder)
    }

    private func decodeAndCompare(_ name: String, _ expected: [(UInt64, UInt64)]) throws {
        let sticker = try XCTUnwrap(WebMStickerDemuxer.parse(try fixture(name)))
        let decoder = try XCTUnwrap(VP9HardwareFrameDecoder(sticker: sticker))
        XCTAssertEqual(VP9HardwareDecoding.activeSessionCount, 2)
        for loop in 0 ..< 2 {
            for (index, frame) in sticker.frames.enumerated() {
                let decoded = try XCTUnwrap(decoder.decode(frame), "frame \(index) loop \(loop)")
                var colorHash: UInt64 = 1469598103934665603
                var alphaHash: UInt64 = 1469598103934665603
                let color = decoded.color
                let width = CVPixelBufferGetWidth(color)
                let height = CVPixelBufferGetHeight(color)
                CVPixelBufferLockBaseAddress(color, .readOnly)
                let y = try unsafe XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(color, 0))
                let cbcr = try unsafe XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(color, 1))
                let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(color, 1)
                unsafe planeHash(y, width: width, height: height, stride: CVPixelBufferGetBytesPerRowOfPlane(color, 0), into: &colorHash)
                unsafe planeHash(cbcr, width: (width + 1) / 2, height: (height + 1) / 2, stride: cbcrStride, step: 2, offset: 0, into: &colorHash)
                unsafe planeHash(cbcr, width: (width + 1) / 2, height: (height + 1) / 2, stride: cbcrStride, step: 2, offset: 1, into: &colorHash)
                CVPixelBufferUnlockBaseAddress(color, .readOnly)
                let alpha = try XCTUnwrap(decoded.alpha)
                CVPixelBufferLockBaseAddress(alpha, .readOnly)
                let a = try unsafe XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(alpha, 0))
                unsafe planeHash(a, width: width, height: height, stride: CVPixelBufferGetBytesPerRowOfPlane(alpha, 0), into: &alphaHash)
                CVPixelBufferUnlockBaseAddress(alpha, .readOnly)
                XCTAssertEqual(colorHash, expected[index].0, "colour of frame \(index) loop \(loop)")
                XCTAssertEqual(alphaHash, expected[index].1, "alpha of frame \(index) loop \(loop)")
            }
            decoder.reset()
        }
        decoder.invalidate()
        XCTAssertEqual(VP9HardwareDecoding.activeSessionCount, 0)
    }

    // Runs where the machine has a hardware VP9 decoder (Apple silicon Macs do).
    func testHardwareFramesMatchLibvpx() throws {
        let probe = VP9HardwareDecoding.probe()
        try XCTSkipUnless(probe.hasHardwareDecoder, "no hardware VP9 decoder: \(probe)")
        try self.decodeAndCompare("sticker_vp9.webm", libvpxHashesSticker30fps)
        try self.decodeAndCompare("sticker_24fps.webm", libvpxHashesSticker24fps)
    }

    func testSessionLimit() throws {
        let probe = VP9HardwareDecoding.probe()
        try XCTSkipUnless(probe.hasHardwareDecoder, "no hardware VP9 decoder: \(probe)")
        let sticker = try XCTUnwrap(WebMStickerDemuxer.parse(try fixture("sticker_vp9.webm")))
        var decoders: [VP9HardwareFrameDecoder] = []
        while decoders.count <= 100, let decoder = VP9HardwareFrameDecoder(sticker: sticker) {
            decoders.append(decoder)
        }
        XCTAssertEqual(decoders.count, VP9HardwareDecoding.maxConcurrentSessions / 2)
        decoders.removeAll()
        XCTAssertEqual(VP9HardwareDecoding.activeSessionCount, 0)
        XCTAssertNotNil(VP9HardwareFrameDecoder(sticker: sticker))
    }
}
