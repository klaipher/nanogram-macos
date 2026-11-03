import Cocoa
import AVFoundation
import SwiftSignalKit
import TGUIKit
import TelegramMedia
import NanogramRuntime

public protocol SystemPictureInPictureSource: AnyObject {
    var pictureInPictureLayer: AVSampleBufferDisplayLayer? { get }
}

private final class SVideoPictureInPicturePlayer: SystemPictureInPicturePlayer {
    private weak var control: SVideoController?
    private let statusDisposable = MetaDisposable()
    private(set) var duration: Double = 0
    private var timestamp: Double = 0
    private var timestampAt: Double = CACurrentMediaTime()
    private var rate: Double = 1
    private var playing: Bool = false
    var statusChanged: (() -> Void)?

    init(control: SVideoController) {
        self.control = control
        self.statusDisposable.set((control.status |> deliverOnMainQueue).start(next: { [weak self] status in
            self?.update(status)
        }))
    }

    deinit {
        self.statusDisposable.dispose()
    }

    private func update(_ status: MediaPlayerStatus) {
        let wasPlaying = self.playing
        let oldDuration = self.duration
        self.duration = status.duration
        self.timestamp = status.timestamp
        self.timestampAt = CACurrentMediaTime()
        self.rate = status.baseRate
        if case .playing = status.status {
            self.playing = true
        } else {
            self.playing = false
        }
        if wasPlaying != self.playing || oldDuration != self.duration {
            self.statusChanged?()
        }
    }

    var isPlaying: Bool {
        return self.control?.isPlaying() ?? false
    }

    var currentTime: Double {
        if self.playing {
            return self.timestamp + (CACurrentMediaTime() - self.timestampAt) * self.rate
        }
        return self.timestamp
    }

    func play() {
        self.control?.play()
    }

    func pause() {
        self.control?.pause()
    }

    func seek(_ timestamp: Double) {
        self.control?.mediaPlayer.seek(timestamp)
    }
}

@available(macOS 12.0, *)
final class SystemPictureInPictureSession {
    let control: PictureInPictureControl
    let viewer: GalleryViewer
    private let item: MGalleryItem
    private let delegate: InteractionContentViewProtocol?
    private let contentInteractions: (any GalleryContentInteractions)?
    private let type: GalleryAppearType
    private let hostWindow: NSWindow
    private let player: SVideoPictureInPicturePlayer
    private var pip: SystemPictureInPicture?
    private var finished = false
    var fallback: (() -> Void)?
    var ended: (() -> Void)?

    init?(control: PictureInPictureControl, viewer: GalleryViewer, item: MGalleryItem, origin: NSPoint, delegate: InteractionContentViewProtocol?, contentInteractions: (any GalleryContentInteractions)?, type: GalleryAppearType) {
        guard let videoController = control as? SVideoController, let layer = (videoController.mediaPlayer as? SystemPictureInPictureSource)?.pictureInPictureLayer else {
            return nil
        }
        self.control = control
        self.viewer = viewer
        self.item = item
        self.delegate = delegate
        self.contentInteractions = contentInteractions
        self.type = type
        self.player = SVideoPictureInPicturePlayer(control: videoController)
        let size = control.view.frame.size
        self.hostWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: max(size.width, 64), height: max(size.height, 64)), styleMask: [.borderless], backing: .buffered, defer: false)
        self.hostWindow.isReleasedWhenClosed = false
        self.hostWindow.ignoresMouseEvents = true
        self.hostWindow.hasShadow = false
        self.hostWindow.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        guard let pip = SystemPictureInPicture(layer: layer, player: self.player) else {
            return nil
        }
        self.pip = pip
        self.player.statusChanged = { [weak pip] in
            pip?.invalidatePlaybackState()
        }
        pip.onFailure = { [weak self] in
            self?.failed()
        }
        pip.onRestore = { [weak self] in
            self?.restore()
        }
        pip.onStop = { [weak self] in
            self?.stopped()
        }
    }

    func start() {
        self.control.view.frame = self.hostWindow.contentLayoutRect.size.bounds
        self.hostWindow.contentView?.addSubview(self.control.view)
        self.hostWindow.orderFrontRegardless()
        self.pip?.start()
    }

    private func tearDown() {
        self.hostWindow.orderOut(nil)
        self.pip?.onStop = nil
        self.pip?.onRestore = nil
        self.pip?.onFailure = nil
    }

    private func failed() {
        guard !self.finished else {
            return
        }
        self.finished = true
        self.tearDown()
        self.control.view.removeFromSuperview()
        self.fallback?()
    }

    private func restore() {
        guard !self.finished else {
            return
        }
        self.finished = true
        self.tearDown()
        self.ended?()
        showGalleryFromPip(item: self.item, gallery: self.viewer, delegate: self.delegate, contentInteractions: self.contentInteractions, type: self.type)
    }

    private func stopped() {
        guard !self.finished else {
            return
        }
        self.finished = true
        self.tearDown()
        self.control.pause()
        self.control.setMode(.normal, animated: false)
        self.ended?()
    }

    func close() {
        guard !self.finished else {
            return
        }
        self.finished = true
        self.tearDown()
        self.pip?.stop()
        self.control.pause()
        self.control.setMode(.normal, animated: false)
    }

    func openGallery() {
        self.pip?.stop()
        self.restore()
    }

    func pause() -> Bool {
        if self.control.isPlaying() {
            self.control.pause()
            return true
        }
        return false
    }

    func play() {
        self.control.play()
    }
}
