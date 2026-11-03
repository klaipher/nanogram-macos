import Foundation
import AVFoundation
import SwiftSignalKit

enum EditVideoStill {
    static func generate(asset: AVAsset, at time: CMTime, maximumSide: CGFloat) -> Signal<CGImage?, NoError> {
        return Signal { subscriber in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: maximumSide, height: maximumSide)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)], completionHandler: { _, image, _, _, _ in
                subscriber.putNext(image)
                subscriber.putCompletion()
            })
            return ActionDisposable {
                generator.cancelAllCGImageGeneration()
            }
        }
    }
}
