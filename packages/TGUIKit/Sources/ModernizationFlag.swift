import Foundation

public enum ModernizationFlag: String, CaseIterable {
    case deferredResizeRelayout = "nanogram.experimental.deferredResizeRelayout"
    case scaledImageCaches = "nanogram.experimental.scaledImageCaches"
    case coalescedMediaProgress = "nanogram.experimental.coalescedMediaProgress"
    case mediaFilePromiseDrag = "nanogram.experimental.mediaFilePromiseDrag"

    public var isEnabled: Bool {
        return UserDefaults.standard.bool(forKey: rawValue)
    }
}
