import Foundation
import Compression

struct LottieFrameCodec {
    let algorithm: compression_algorithm
    let fileTag: String

    static let lzfse = LottieFrameCodec(algorithm: COMPRESSION_LZFSE, fileTag: "lzfse")

    static let lz4 = LottieFrameCodec(algorithm: COMPRESSION_LZ4, fileTag: "lz4")

    static var current: LottieFrameCodec {
        return .lz4
    }

    var encodeScratchSize: Int {
        return compression_encode_scratch_buffer_size(self.algorithm)
    }

    var decodeScratchSize: Int {
        return compression_decode_scratch_buffer_size(self.algorithm)
    }

    func encode(_ source: UnsafePointer<UInt8>, count: Int, into destination: UnsafeMutablePointer<UInt8>, capacity: Int, scratch: UnsafeMutableRawPointer?) -> Int {
        return compression_encode_buffer(destination, capacity, source, count, scratch, self.algorithm)
    }

    func decode(_ source: UnsafePointer<UInt8>, count: Int, into destination: UnsafeMutablePointer<UInt8>, capacity: Int, scratch: UnsafeMutableRawPointer?) -> Int {
        return compression_decode_buffer(destination, capacity, source, count, scratch, self.algorithm)
    }
}
