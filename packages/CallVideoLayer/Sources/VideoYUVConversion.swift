import Foundation
import CoreVideo
import simd

public struct VideoYUVConversion: Equatable {
    public enum Matrix: Equatable {
        case bt601
        case bt709
        case bt2020

        var lumaCoefficients: (red: Float, blue: Float) {
            switch self {
            case .bt601:
                return (0.299, 0.114)
            case .bt709:
                return (0.2126, 0.0722)
            case .bt2020:
                return (0.2627, 0.0593)
            }
        }
    }

    public struct ShaderParameters {
        public var column0: SIMD4<Float>
        public var column1: SIMD4<Float>
        public var column2: SIMD4<Float>
        public var offset: SIMD4<Float>
        public var scale: SIMD4<Float>
    }

    public let matrix: Matrix
    public let isFullRange: Bool

    public static let fullRange601 = VideoYUVConversion(matrix: .bt601, isFullRange: true)

    public init(matrix: Matrix, isFullRange: Bool) {
        self.matrix = matrix
        self.isFullRange = isFullRange
    }

    public init(pixelBuffer: CVPixelBuffer) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isFullRange: Bool
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
            isFullRange = false
        default:
            isFullRange = true
        }
        let matrix: Matrix
        let tag = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        if tag == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String {
            matrix = .bt709
        } else if tag == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {
            matrix = .bt2020
        } else {
            matrix = .bt601
        }
        self.init(matrix: matrix, isFullRange: isFullRange)
    }

    public var rgbFromYCbCr: simd_float3x3 {
        let (kr, kb) = self.matrix.lumaCoefficients
        let kg = 1.0 - kr - kb
        let crToRed = 2.0 * (1.0 - kr)
        let cbToBlue = 2.0 * (1.0 - kb)
        let cbToGreen = -2.0 * kb * (1.0 - kb) / kg
        let crToGreen = -2.0 * kr * (1.0 - kr) / kg
        return simd_float3x3(columns: (
            SIMD3<Float>(1.0, 1.0, 1.0),
            SIMD3<Float>(0.0, cbToGreen, cbToBlue),
            SIMD3<Float>(crToRed, crToGreen, 0.0)
        ))
    }

    public var offset: SIMD3<Float> {
        return self.isFullRange ? SIMD3<Float>(0.0, 0.5, 0.5) : SIMD3<Float>(16.0 / 255.0, 0.5, 0.5)
    }

    public var scale: SIMD3<Float> {
        return self.isFullRange ? SIMD3<Float>(1.0, 1.0, 1.0) : SIMD3<Float>(255.0 / 219.0, 255.0 / 224.0, 255.0 / 224.0)
    }

    public var shaderParameters: ShaderParameters {
        let matrix = self.rgbFromYCbCr
        return ShaderParameters(
            column0: SIMD4<Float>(matrix.columns.0, 0.0),
            column1: SIMD4<Float>(matrix.columns.1, 0.0),
            column2: SIMD4<Float>(matrix.columns.2, 0.0),
            offset: SIMD4<Float>(self.offset, 0.0),
            scale: SIMD4<Float>(self.scale, 0.0)
        )
    }

    public func rgb(y: Float, cb: Float, cr: Float) -> SIMD3<Float> {
        let normalized = (SIMD3<Float>(y, cb, cr) - self.offset) * self.scale
        return self.rgbFromYCbCr * normalized
    }
}
