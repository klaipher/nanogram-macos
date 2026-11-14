import Foundation
import AVFoundation
import CoreGraphics
import SwiftSignalKit

public enum VideoFirstFrameGenerator {
    public static let debugOptionId = "media.asyncVideoFirstFrame"

    public static var isEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "nanogram.debug." + debugOptionId)
    }

    static func makeAsset(path: String, mimeType: String) -> AVURLAsset {
        return AVURLAsset(url: URL(fileURLWithPath: path), options: [AVURLAssetOverrideMIMETypeKey: mimeType])
    }

    public static func firstFrame(path: String, maxSize: CGSize, mimeType: String) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: makeAsset(path: path, mimeType: mimeType))
        generator.maximumSize = maxSize
        generator.appliesPreferredTrackTransform = true
        return await withTaskCancellationHandler {
            return try? await generator.image(at: .zero).image
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    public static func signal(path: String, maxSize: CGSize, mimeType: String) -> Signal<CGImage?, NoError> {
        return Signal { subscriber in
            let task = Task {
                let image = await firstFrame(path: path, maxSize: maxSize, mimeType: mimeType)
                if !Task.isCancelled {
                    subscriber.putNext(image)
                    subscriber.putCompletion()
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }
}
