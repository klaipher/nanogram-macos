import Foundation
import AVFoundation
import AVKit
import NanogramDebug

public protocol SystemPictureInPicturePlayer: AnyObject {
    var isPlaying: Bool { get }
    var duration: Double { get }
    var currentTime: Double { get }
    func play()
    func pause()
    func seek(_ timestamp: Double)
}

public final class SystemPictureInPicture: NSObject {
    public static let debugOption = NanogramDebugOption.toggle(id: "media.systemPictureInPicture", section: "Media", title: "System picture-in-picture for videos", detail: "Gallery videos go to macOS picture-in-picture (system controls, Spaces, Stage Manager) instead of Telegram's floating player. Telegram's player stays for web and HLS videos and when the system cannot start.", defaultValue: false)

    public static func isEnabled(in settings: NanogramDebugSettings) -> Bool {
        if settings.isOverridden(SystemPictureInPicture.debugOption.id) {
            return settings.bool(SystemPictureInPicture.debugOption.id)
        }
        if case let .toggle(defaultValue) = SystemPictureInPicture.debugOption.kind {
            return defaultValue
        }
        return false
    }

    public static var isEnabled: Bool {
        return SystemPictureInPicture.isEnabled(in: NanogramDebugSettings.shared)
    }

    public var onFailure: (() -> Void)?
    public var onStart: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onRestore: (() -> Void)?

    private weak var player: SystemPictureInPicturePlayer?
    private var possibleObservation: NSKeyValueObservation?
    private var timeoutWork: DispatchWorkItem?
    private var finished = false
    private var failed = false
    private var stopped = false
    private var anyController: AnyObject?

    @available(macOS 12.0, *)
    public var controller: AVPictureInPictureController {
        return self.anyController as! AVPictureInPictureController
    }

    @available(macOS 12.0, *)
    public init?(layer: AVSampleBufferDisplayLayer, player: SystemPictureInPicturePlayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return nil
        }
        self.player = player
        super.init()
        let controller = AVPictureInPictureController(contentSource: AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self))
        controller.delegate = self
        self.anyController = controller
    }

    @available(macOS 12.0, *)
    public func start(timeout: TimeInterval = 2.0) {
        self.finished = false
        self.failed = false
        let work = DispatchWorkItem { [weak self] in
            if let self = self, !self.finished {
                self.fail()
            }
        }
        self.timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        self.possibleObservation = self.controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            guard controller.isPictureInPicturePossible else {
                return
            }
            DispatchQueue.main.async {
                guard let self = self, !self.finished else {
                    return
                }
                self.finished = true
                self.timeoutWork?.cancel()
                self.possibleObservation = nil
                self.controller.startPictureInPicture()
            }
        }
    }

    @available(macOS 12.0, *)
    public func stop() {
        self.timeoutWork?.cancel()
        self.possibleObservation = nil
        if self.controller.isPictureInPictureActive {
            self.controller.stopPictureInPicture()
        }
    }

    @available(macOS 12.0, *)
    public func invalidatePlaybackState() {
        self.controller.invalidatePlaybackState()
    }

    private func fail() {
        guard !self.failed else {
            return
        }
        self.failed = true
        self.finished = true
        self.timeoutWork?.cancel()
        self.possibleObservation = nil
        self.onFailure?()
    }

    private func notifyStop() {
        guard !self.stopped else {
            return
        }
        self.stopped = true
        self.onStop?()
    }
}

@available(macOS 12.0, *)
extension SystemPictureInPicture: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing {
            self.player?.play()
        } else {
            self.player?.pause()
        }
    }

    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        guard let duration = self.player?.duration, duration > 0, duration.isFinite else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return !(self.player?.isPlaying ?? false)
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        if let player = self.player {
            var target = player.currentTime + skipInterval.seconds
            target = max(0, target)
            if player.duration > 0 {
                target = min(player.duration, target)
            }
            player.seek(target)
        }
        completionHandler()
    }

    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        self.onStart?()
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        self.fail()
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        self.onRestore?()
        completionHandler(true)
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        self.notifyStop()
    }
}
