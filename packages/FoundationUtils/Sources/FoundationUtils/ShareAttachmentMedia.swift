import Foundation
import ImageIO
import CoreServices

public enum ShareAttachmentMedia {
    public static let maxImagePixelSize = 1280
    public static let jpegQuality = 0.83

    public static func imageType(ofFileAt url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return imageType(of: source)
    }

    public static func imageType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return imageType(of: source)
    }

    public static func fileData(at url: URL) -> Data? {
        return try? Data(contentsOf: url, options: [.alwaysMapped])
    }

    public static func downsampledJPEG(fileAt url: URL, maxPixelSize: Int = maxImagePixelSize) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return downsampledJPEG(source: source, maxPixelSize: maxPixelSize)
    }

    public static func downsampledJPEG(data: Data, maxPixelSize: Int = maxImagePixelSize) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return downsampledJPEG(source: source, maxPixelSize: maxPixelSize)
    }

    public static func downsampledJPEG(image: CGImage, maxPixelSize: Int = maxImagePixelSize) -> Data? {
        let longestSide = max(image.width, image.height)
        guard longestSide > 0 else {
            return nil
        }
        if longestSide <= maxPixelSize {
            return jpegData(image)
        }
        let scale = Double(maxPixelSize) / Double(longestSide)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            return nil
        }
        return jpegData(scaled)
    }

    private static func imageType(of source: CGImageSource) -> String? {
        guard let type = CGImageSourceGetType(source), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return type as String
    }

    private static func downsampledJPEG(source: CGImageSource, maxPixelSize: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return jpegData(image)
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, kUTTypeJPEG, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}
