import Foundation
import CoreGraphics
import ImageIO

enum PhotoSourceReading {
    static func source(at path: String) -> CGImageSource? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        return CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options as CFDictionary)
    }

    static func thumbnail(of source: CGImageSource, maxPixelSize: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func pixelSize(at path: String) -> CGSize? {
        guard let source = source(at: path),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}
