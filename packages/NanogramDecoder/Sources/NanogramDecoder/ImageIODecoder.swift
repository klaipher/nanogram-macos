import Foundation
import ImageIO
import CoreGraphics

public enum ImageIODecoder {
    public static func decode(_ data: Data, maxPixelSize: Int, limits: DecoderLimits) throws -> DecodedBitmap {
        guard data.count <= limits.maxImageBytes else {
            throw DecoderError.inputTooLarge
        }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary), CGImageSourceGetCount(source) >= 1 else {
            throw DecoderError.decodeFailed
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary) as? [CFString: Any],
              let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              sourceWidth > 0, sourceHeight > 0 else {
            throw DecoderError.decodeFailed
        }
        guard sourceWidth <= limits.maxSourcePixels / sourceHeight else {
            throw DecoderError.inputTooLarge
        }
        let target = min(max(maxPixelSize, 1), limits.maxFrameDimension)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw DecoderError.decodeFailed
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= limits.maxFrameDimension, height <= limits.maxFrameDimension else {
            throw DecoderError.invalidDimensions
        }
        let bytesPerRow = width * 4
        guard bytesPerRow * height <= limits.maxFrameBytes else {
            throw DecoderError.invalidDimensions
        }
        var pixels = Data(count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw DecoderError.decodeFailed
        }
        return DecodedBitmap(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }
}
