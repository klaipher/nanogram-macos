import Foundation
import CoreVideo
import YuvConversion

public final class VP9HardwareStickerReader {
    public static let probeResult: VP9HardwareProbeResult = VP9HardwareDecoding.probe()

    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let frameRate: Int
    public let frameCount: Int

    private let sticker: WebMSticker
    private let decoder: VP9HardwareFrameDecoder
    private let unpremultiplyAlpha: Bool
    private var nextFrame = 0
    private let argb: UnsafeMutablePointer<UInt8>
    private let cb: UnsafeMutablePointer<UInt8>
    private let cr: UnsafeMutablePointer<UInt8>
    private let alpha: UnsafeMutablePointer<UInt8>
    private let lumaStride: Int

    // `isResume` marks a reader set up again for a sticker that gave its sessions back (counted as a resume, not as
    // a start). The file is not read or parsed when every hardware session slot is taken.
    public convenience init?(path: String, unpremultiplyAlpha: Bool, isResume: Bool = false) {
        guard VP9HardwareStickerReader.probeResult.hasHardwareDecoder else {
            return nil
        }
        guard let sticker = VP9HardwareDecoding.loadSticker({ try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) }) else {
            return nil
        }
        self.init(sticker: sticker, unpremultiplyAlpha: unpremultiplyAlpha, isResume: isResume)
    }

    public convenience init?(data: Data, unpremultiplyAlpha: Bool, isResume: Bool = false) {
        guard let sticker = WebMStickerDemuxer.parse(data) else {
            return nil
        }
        self.init(sticker: sticker, unpremultiplyAlpha: unpremultiplyAlpha, isResume: isResume)
    }

    private init?(sticker: WebMSticker, unpremultiplyAlpha: Bool, isResume: Bool) {
        guard sticker.width > 1, sticker.height > 1, sticker.width % 2 == 0, sticker.height % 2 == 0, !sticker.frames.isEmpty else {
            return nil
        }
        guard let decoder = VP9HardwareFrameDecoder(sticker: sticker, isResume: isResume) else {
            return nil
        }
        self.sticker = sticker
        self.decoder = decoder
        self.unpremultiplyAlpha = unpremultiplyAlpha
        self.width = sticker.width
        self.height = sticker.height
        self.bytesPerRow = sticker.width * 4
        self.lumaStride = sticker.width
        self.frameCount = sticker.frames.count
        self.frameRate = max(1, Int((sticker.frameRate ?? 30.0).rounded()))
        self.argb = .allocate(capacity: self.bytesPerRow * sticker.height)
        self.cb = .allocate(capacity: (sticker.width / 2) * (sticker.height / 2))
        self.cr = .allocate(capacity: (sticker.width / 2) * (sticker.height / 2))
        self.alpha = .allocate(capacity: sticker.width * sticker.height)
    }

    deinit {
        self.decoder.invalidate()
        self.argb.deallocate()
        self.cb.deallocate()
        self.cr.deallocate()
        self.alpha.deallocate()
    }

    public var hasMoreFrames: Bool {
        return self.nextFrame < self.frameCount
    }

    public func rewind() {
        self.decoder.reset()
        self.nextFrame = 0
    }

    public func skipFrames(_ count: Int) -> Bool {
        guard count >= 0, count <= self.frameCount - self.nextFrame else {
            return false
        }
        for _ in 0 ..< count {
            let frame = self.sticker.frames[self.nextFrame]
            self.nextFrame += 1
            guard self.decoder.decode(frame) != nil else {
                return false
            }
        }
        return true
    }

    public var framesRead: Int {
        return self.nextFrame
    }

    public func readFrame(_ body: (UnsafePointer<UInt8>, Int, Int, Int) -> Void) -> Bool {
        guard self.nextFrame < self.frameCount else {
            return false
        }
        let frame = self.sticker.frames[self.nextFrame]
        self.nextFrame += 1
        guard let decoded = self.decoder.decode(frame) else {
            return false
        }
        guard self.convert(decoded) else {
            return false
        }
        body(UnsafePointer(self.argb), self.width, self.height, self.bytesPerRow)
        return true
    }

    private func convert(_ frame: VP9DecodedFrame) -> Bool {
        let color = frame.color
        guard CVPixelBufferGetWidth(color) >= self.width, CVPixelBufferGetHeight(color) >= self.height, CVPixelBufferGetPlaneCount(color) == 2 else {
            return false
        }
        CVPixelBufferLockBaseAddress(color, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(color, .readOnly)
        }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(color, 0), let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(color, 1) else {
            return false
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(color, 0)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(color, 1)
        let chromaWidth = self.width / 2
        let chromaHeight = self.height / 2
        let cbcr = cbcrBase.assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< chromaHeight {
            let row = cbcr + y * cbcrStride
            let cbRow = self.cb + y * chromaWidth
            let crRow = self.cr + y * chromaWidth
            for x in 0 ..< chromaWidth {
                cbRow[x] = row[x * 2]
                crRow[x] = row[x * 2 + 1]
            }
        }
        var hasAlpha = false
        if let alphaBuffer = frame.alpha {
            CVPixelBufferLockBaseAddress(alphaBuffer, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(alphaBuffer, .readOnly)
            }
            guard let alphaBase = CVPixelBufferGetBaseAddressOfPlane(alphaBuffer, 0), CVPixelBufferGetWidth(alphaBuffer) >= self.width, CVPixelBufferGetHeight(alphaBuffer) >= self.height else {
                return false
            }
            let alphaStride = CVPixelBufferGetBytesPerRowOfPlane(alphaBuffer, 0)
            let source = alphaBase.assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< self.height {
                memcpy(self.alpha + y * self.lumaStride, source + y * alphaStride, self.width)
            }
            hasAlpha = true
        }
        let luma = yBase.assumingMemoryBound(to: UInt8.self)
        if yStride == self.lumaStride {
            decodeYUVAPlanesToRGBA(luma, Int32(yStride), self.cb, Int32(chromaWidth), self.cr, Int32(chromaWidth), hasAlpha, self.alpha, self.argb, Int32(self.width), Int32(self.height), Int32(self.bytesPerRow), self.unpremultiplyAlpha)
        } else {
            let packed = UnsafeMutablePointer<UInt8>.allocate(capacity: self.lumaStride * self.height)
            defer {
                packed.deallocate()
            }
            for y in 0 ..< self.height {
                memcpy(packed + y * self.lumaStride, luma + y * yStride, self.width)
            }
            decodeYUVAPlanesToRGBA(packed, Int32(self.lumaStride), self.cb, Int32(chromaWidth), self.cr, Int32(chromaWidth), hasAlpha, self.alpha, self.argb, Int32(self.width), Int32(self.height), Int32(self.bytesPerRow), self.unpremultiplyAlpha)
        }
        return true
    }
}
