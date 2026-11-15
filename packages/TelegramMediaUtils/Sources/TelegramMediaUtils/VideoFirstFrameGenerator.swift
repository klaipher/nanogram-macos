import Foundation
import AVFoundation
import CoreGraphics
import SwiftSignalKit

/// Carries a reference that is only touched through thread-safe entry points, so the task closures
/// below capture nothing but Sendable values.
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) {
        self.value = value
    }
}

public enum VideoFirstFrameGenerator {
    public static let debugOptionId = "media.asyncVideoFirstFrame"

    public static var isEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "nanogram.debug." + debugOptionId)
    }

    @available(macOS 14.0, *)
    static func makeAsset(path: String, mimeType: String) -> AVURLAsset {
        return AVURLAsset(url: URL(fileURLWithPath: path), options: [AVURLAssetOverrideMIMETypeKey: mimeType])
    }

    @available(macOS 14.0, *)
    public static func firstFrame(path: String, maxSize: CGSize, mimeType: String) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: makeAsset(path: path, mimeType: mimeType))
        generator.maximumSize = maxSize
        generator.appliesPreferredTrackTransform = true
        let box = UncheckedSendableBox(generator)
        return await withTaskCancellationHandler {
            return try? await box.value.image(at: .zero).image
        } onCancel: {
            box.value.cancelAllCGImageGeneration()
        }
    }

    @available(macOS 14.0, *)
    public static func signal(path: String, maxSize: CGSize, mimeType: String) -> Signal<CGImage?, NoError> {
        return Signal { subscriber in
            let box = UncheckedSendableBox(subscriber)
            let task = Task {
                let image = await firstFrame(path: path, maxSize: maxSize, mimeType: mimeType)
                if !Task.isCancelled {
                    box.value.putNext(image)
                    box.value.putCompletion()
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }
}
