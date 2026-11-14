import Foundation
import TGUIKit

struct PhotoCacheSizing: Equatable {
    static let megabyte = 1024 * 1024

    let photosByteLimit: Int
    let photoThumbsByteLimit: Int
    let photosClosedScopeGrace: TimeInterval

    static let legacy = PhotoCacheSizing(photosByteLimit: 24 * megabyte, photoThumbsByteLimit: 6 * megabyte, photosClosedScopeGrace: 15)

    static func scaled(physicalMemory: UInt64) -> PhotoCacheSizing {
        let memory = Int(clamping: physicalMemory)
        let photos = min(max(memory / 256, 24 * megabyte), 96 * megabyte)
        let thumbs = min(max(memory / 1024, 6 * megabyte), 24 * megabyte)
        return PhotoCacheSizing(photosByteLimit: photos, photoThumbsByteLimit: thumbs, photosClosedScopeGrace: 60)
    }

    static func current(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory, flagEnabled: Bool = ModernizationFlag.scaledImageCaches.isEnabled) -> PhotoCacheSizing {
        return flagEnabled ? scaled(physicalMemory: physicalMemory) : legacy
    }
}
