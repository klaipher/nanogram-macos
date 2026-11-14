import Cocoa
import Foundation
import TGUIKit
import TelegramCore
import Postbox
import SwiftSignalKit
import ColorPalette
import InAppSettings
import TelegramTheme
import TelegramContext
import TelegramUtils
import TelegramMedia
import TelegramMediaUtils
import ObjcUtils
import TGVideoCameraMovie
import AVFoundation
import GZIP

private let videoCameraRetainedBufferCount:Int = 16;

private let roundVideoPlaneFrameCount = 27

let roundVideoDecorationIsEnabled = false

func applyRoundVideoDecoration(to renderer: TGVideoCameraRenderer, decoration: () -> (watermark: CGImage, planeFrames: CGImage)? = roundVideoDecoration) {
    guard roundVideoDecorationIsEnabled, let decoration = decoration() else {
        return
    }
    renderer.setDecorationWatermark(decoration.watermark, planeFrames: decoration.planeFrames, planeFrameCount: roundVideoPlaneFrameCount)
}

private func roundVideoDecoration() -> (watermark: CGImage, planeFrames: CGImage)? {
    guard let watermark = NSImage(named: "RoundVideoCorner")?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
    }
    guard let data = NSDataAsset(name: "PlaneLogoPlain")?.data, let unzipped = TGGUnzipData(data, 5 * 1024 * 1024), let json = String(data: unzipped, encoding: .utf8), let animation = LottieRenderHooks.shared.makeRenderer(json) else {
        return nil
    }
    let frameSize = 68
    let bytesPerRow = frameSize * 4
    let frameByteCount = bytesPerRow * frameSize
    var bytes = Data(count: frameByteCount * roundVideoPlaneFrameCount)
    bytes.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return
        }
        for index in 0 ..< roundVideoPlaneFrameCount {
            animation.renderFrame(with: Int32(index * 2), into: base.advanced(by: index * frameByteCount), width: Int32(frameSize), height: Int32(frameSize), bytesPerRow: Int32(bytesPerRow))
        }
    }
    let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
    guard let provider = CGDataProvider(data: bytes as CFData), let planeFrames = CGImage(width: frameSize, height: frameSize * roundVideoPlaneFrameCount, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
        return nil
    }
    return (watermark, planeFrames)
}

public class VideoRecorderPipeline : NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, TGVideoCameraMovieRecorderDelegate, AVCaptureAudioDataOutputSampleBufferDelegate  {
    
    
    public func movieRecorderDidFinishPreparing(_ recorder: TGVideoCameraMovieRecorder!) {
        
    }
    
    public func movieRecorder(_ recorder: TGVideoCameraMovieRecorder!, didFailWithError error: Error!) {
        status = .failed
    }
    
    public func movieRecorderDidFinishRecording(_ recorder: TGVideoCameraMovieRecorder!) {
        VideoRecorderPipeline.queue.async {
            self.segments.append(self.currentURL)
            self.completedDuration += self.lastSegmentDuration
            self.lastSegmentDuration = 0
            
            switch self.status {
            case .startingRecording, .recording, .madeThumbnail:
                self.composedRecording { [weak self] result in
                    guard let self, !self.isDiscarded, self.isPaused else { return }
                    guard let (path, duration) = result else {
                        self.status = .failed
                        return
                    }
                    self.status = .paused(info: ChatRecordingPreviewData(path: path, duration: duration, waveform: nil, thumb: self.thumbnail))
                }
            default:
                self.finishWithComposedResult()
            }
        }
    }
    
    
    
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoConnection:AVCaptureConnection?
    private var videoDevice: AVCaptureDevice?
    
    private var audioDeviceInput: AVCaptureDeviceInput?
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioConnection:AVCaptureConnection?
    private var audioDevice: AVCaptureDevice?

    
    private var outputVideoFormatDescription: CMFormatDescription?
    private var outputAudioFormatDescription: CMFormatDescription?
    
    public private(set) var thumbnail:CGImage?
    
    public let session: AVCaptureSession = AVCaptureSession()
    
    public let config: VideoMessageConfig
    public let outputSide: Int
    
    private var status: VideoCameraRecordingStatus = .idle {
        didSet {
            statePromise.set(status)
        }
    }
    
    public let statePromise:ValuePromise<VideoCameraRecordingStatus> = ValuePromise(.idle, ignoreRepeated: true)
    public let powerAndDuration: Promise<(Float, Double)> = Promise()
    
    public var pausedInfo: Signal<ChatRecordingPreviewData?, NoError> {
        return statePromise.get() |> map { state in
            if case let .paused(info) = state {
                return info
            }
            return nil
        } |> distinctUntilChanged
    }
    
    private let renderer: TGVideoCameraRenderer = (TGVideoCameraMetalRenderer() as TGVideoCameraRenderer?) ?? TGVideoCameraGLRenderer()
    private var renderingEnabled: Bool = false

    private var recorder: TGVideoCameraMovieRecorder!
    
    
    private let path: String
    private let url:URL
    private var currentURL: URL
    private var segments: [URL] = []
    private var derivedFiles: [String] = []
    private var composedFile: String?
    private var compositionRequestId = UUID()
    private var sentPath: String?
    private var isDiscarded: Bool = false
    private var completedDuration: Double = 0
    private var lastSegmentDuration: Double = 0
    private var isPaused: Bool = false
    private let composeDisposable = MetaDisposable()
    
    private var currentSegmentDuration: Double {
        let duration = recorder.videoDuration()
        return duration.isNaN ? 0 : duration
    }
    
    private var resultDuration: Int = 0
    private var startTimeInterval: TimeInterval = 0
    private var decorationStartTime: CMTime?

    private static let queue: Queue = Queue(name: "org.telegram.InstantVideoQueue")
    
    private let startRecordAfterAudioBuffer:Atomic<Bool> = Atomic(value: false)
    private var resumeAfterAudioBuffer: Bool = false
    private var deviceObservers: [NSObjectProtocol] = []
    private var pipelineSetupFailed: Bool = false

    public static let videoMessageMaxDuration: Double = 60

    private var liveUploading: PreUploadManager?
    public init(path: String, config: VideoMessageConfig, liveUploading: PreUploadManager?, audioInputDeviceId: String? = nil) {
        self.path = path
        let url = URL(fileURLWithPath: path)
        self.url = url
        self.currentURL = url
        self.liveUploading = liveUploading
        self.config = config
        self.outputSide = TGMediaVideoConversionPresetSettings.videoMessageSide(forDiameter: RoundVideoEncodingPolicy.side(serverDiameter: config.diameter))
        super.init()
        
        recorder = TGVideoCameraMovieRecorder(url: url, delegate: self, callbackQueue: VideoRecorderPipeline.queue.queue)
        
        renderer.orientation = .portrait
        renderer.mirror = true
        renderer.outputSide = self.outputSide
        applyRoundVideoDecoration(to: renderer)
        
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .medium
        }
        

        let defAudioDevice = AVCaptureDevice.default(for: .audio)
        let defVideoDevice = AVCaptureDevice.default(for: .video)
        
        
        var videoDevices = AVCaptureDevice.devices(for: .video).filter({ $0.isConnected && !$0.isSuspended })
        var audioDevices = AVCaptureDevice.devices(for: .audio)

        if !videoDevices.isEmpty, let device = defVideoDevice {
            videoDevices.insert(device, at: 0)
        }
        if !audioDevices.isEmpty, let device = defAudioDevice {
            audioDevices.insert(device, at: 0)
        }
            
        let videoDevice = videoDevices.filter({ $0.isConnected && !$0.isSuspended }).first(where: { $0.position == .front || $0.position == .unspecified })
        
        let audioDevice = audioDevices.first(where: { $0.uniqueID == audioInputDeviceId && $0.isConnected && !$0.isSuspended }) ?? audioDevices.first(where: { $0.isConnected && !$0.isSuspended})


        if let videoDevice = videoDevice {
            setSelectedVideoDevice(videoDevice)
        } else if let videoDevice = AVCaptureDevice.default(for: .muxed) {
            setSelectedVideoDevice(videoDevice)
        }
        
        if let audioDevice = audioDevice {
            setSelectedAudioDevice(audioDevice)
        }
        
        videoOutput.alwaysDiscardsLateVideoFrames = false

        videoOutput.videoSettings = captureVideoSettings()
        
        videoOutput.setSampleBufferDelegate(self, queue: VideoRecorderPipeline.queue.queue)
        session.addOutput(videoOutput)

        audioOutput.setSampleBufferDelegate(self, queue: VideoRecorderPipeline.queue.queue)
        
        
        session.addOutput(audioOutput)
        
        
        videoConnection = videoOutput.connection(with: .video)
        audioConnection = audioOutput.connection(with: .audio)
        
        self.observeCaptureInterruptions()

        
        _configureFps()
    }
    
    private func _configureFps() {
        
        //let frameDuration = CMTimeMake(1, 30)
        
        if let videoDevice = videoDevice {
            _reconfigureDevice(videoDevice, with: { device in
                let fps = Double(RoundVideoEncodingPolicy.frameRate)
                guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && $0.maxFrameRate >= fps }) else {
                    return
                }
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(RoundVideoEncodingPolicy.frameRate))
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
            })
        }
    }
    
    private func _reconfigureDevice(_ device: AVCaptureDevice, with block: (AVCaptureDevice)-> Void) {
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        defer { device.unlockForConfiguration() }
        block(device)
    }
    

    private func setSelectedAudioDevice(_ device: AVCaptureDevice) {
        self.audioDevice = device
        session.beginConfiguration()
        if let audioDeviceInput = audioDeviceInput {
            session.removeInput(audioDeviceInput)
            self.audioDeviceInput = nil
        }
        if let audioDeviceInput = try? AVCaptureDeviceInput(device: device)  {
            if !device.supportsSessionPreset(session.sessionPreset) {
                session.sessionPreset = .high
            }
            session.addInput(audioDeviceInput)
            self.audioDeviceInput = audioDeviceInput
        }
        session.commitConfiguration()
    }
    
    private func setSelectedVideoDevice(_ device: AVCaptureDevice) {
        self.videoDevice = device
        
        session.beginConfiguration()
        if let videoDeviceInput = videoDeviceInput {
            session.removeInput(videoDeviceInput)
            self.videoDeviceInput = nil
        }
        if let videoDeviceInput = try? AVCaptureDeviceInput(device: device)  {
            if !device.supportsSessionPreset(session.sessionPreset) {
                session.sessionPreset = .high
            }
            session.addInput(videoDeviceInput)
            self.videoDeviceInput = videoDeviceInput
        }
        session.commitConfiguration()
        _configureFps()
        videoOutput.videoSettings = captureVideoSettings()
    }

    private func captureVideoSettings() -> [String: Any] {
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        if let device = videoDevice {
            let source = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let capped = TGVideoCameraCaptureDimensions(source)
            if capped.width != source.width || capped.height != source.height {
                settings[kCVPixelBufferWidthKey as String] = Int(capped.width)
                settings[kCVPixelBufferHeightKey as String] = Int(capped.height)
            }
        }
        return settings
    }
  
    
    
    
    private func setupVideoPipelineWithInputFormatDescription(_ inputFormatDescription: CMFormatDescription) {
        let prepared = renderer.prepareForInput(with: inputFormatDescription, outputRetainedBufferCountHint: videoCameraRetainedBufferCount)
        self.outputVideoFormatDescription = renderer.outputFormatDescription
        
        if !prepared || self.outputVideoFormatDescription == nil {
            self.pipelineSetupFailed = true
            self.status = .failed
            return
        }
        
        self.startRecording()
    }
    

   
    private let skip:Atomic<Int32> = Atomic(value: 0)
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        
        
        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
        
        if self.skip.modify({ $0 + 1 }) < 10 {
            return
        }
        
        if connection == self.videoConnection, let formatDescription = formatDescription {
            
            if self.outputVideoFormatDescription != nil {
                self.renderVideoSampleBuffer(sampleBuffer)
            } else if !pipelineSetupFailed {
                self.setupVideoPipelineWithInputFormatDescription(formatDescription)
            }
            
            
        } else if connection == self.audioConnection {
            self.outputAudioFormatDescription = formatDescription
            
            if startRecordAfterAudioBuffer.swap(false) {
                self.startRecording()
                return
            }
            
            if self.resumeAfterAudioBuffer {
                self.resumeAfterAudioBuffer = false
                self.continueRecordingAfterResume()
                return
            }
            
            if isPaused {
                return
            }
            
            recorder.appendAudioSampleBuffer(sampleBuffer)
            
            if renderingEnabled {
                lastSegmentDuration = currentSegmentDuration
                let duration = completedDuration + lastSegmentDuration
                let power = connection.audioChannels.map { Float(mappingRange(Double($0.averagePowerLevel), -60, 0, 0, 1)) }.max() ?? 0
                powerAndDuration.set(.single((power, duration)))
            }
        }
        liveUploading?.fileDidChangedSize(false)
    }
    

    
    private func renderVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        var renderedPixelBuffer: CVPixelBuffer? = nil
        let timestamp: CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if renderingEnabled, !isPaused, let sourcePixelBuffer: CVPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let decorationStartTime = self.decorationStartTime ?? timestamp
            self.decorationStartTime = decorationStartTime
            let decorationTime = CMTimeGetSeconds(CMTimeSubtract(timestamp, decorationStartTime))
            renderer.decorationFrame = decorationTime.isFinite ? Int(max(0, decorationTime) * 30) : 0

            renderedPixelBuffer = renderer.copyRenderedPixelBuffer(sourcePixelBuffer).takeRetainedValue()
            
        }
        if let renderedPixelBuffer = renderedPixelBuffer {
            if thumbnail == nil {
                if let thumb = renderedPixelBuffer.cgImage {
                    status = .madeThumbnail(thumb)
                    thumbnail = thumb
                }
            }
            recorder?.appendVideoPixelBuffer(renderedPixelBuffer, withPresentationTime: timestamp)
        }
        
    }
    



    private func startRecording() {
        
        if renderingEnabled {
            return
        }

        if outputAudioFormatDescription == nil {
            _ = startRecordAfterAudioBuffer.swap(true)
            return
        }

        renderingEnabled = true
        status = .recording
        startTimeInterval = Date().timeIntervalSince1970

        configureRecorderTracks()
    }
    
    private func configureRecorderTracks() {
        let sourceSampleRate = self.outputAudioFormatDescription.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48000.0
        let audioSettings = TGMediaVideoConversionPresetSettings.audioSettings(for: TGMediaVideoConversionPresetVideoMessage, bitrate: Int32(RoundVideoEncodingPolicy.audioBitrateKbps(server: config.audioBitrate)), sourceSampleRate: sourceSampleRate)
        recorder.addAudioTrack(withSourceFormatDescription: outputAudioFormatDescription, settings: audioSettings)
        let producedSide = self.outputVideoFormatDescription.map { description -> Int in
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            return Int(min(dimensions.width, dimensions.height))
        } ?? self.outputSide
        let writerSide = RoundVideoEncodingPolicy.effectiveSide(side: self.outputSide, sourceShortSide: producedSide)
        let size = CGSize(width: writerSide, height: writerSide)
        let videoSettings = TGMediaVideoConversionPresetSettings.videoSettings(for: TGMediaVideoConversionPresetVideoMessage, dimensions: size, bitrate: Int32(RoundVideoEncodingPolicy.videoBitrateKbps(server: config.videoBitrate)))
        recorder.addVideoTrack(withSourceFormatDescription: outputVideoFormatDescription, transform: CGAffineTransform.identity, settings: videoSettings)
        
        recorder.prepareToRecord()
    }
    
    public func pause() {
        VideoRecorderPipeline.queue.async {
            guard !self.isPaused, self.renderingEnabled else {
                return
            }
            self.lastSegmentDuration = self.currentSegmentDuration
            self.isPaused = true
            self.renderingEnabled = false
            self.recorder.finishRecording()
            self.closeMicrophone()
        }
    }
    
    private func closeMicrophone() {
        guard let audioDeviceInput = self.audioDeviceInput else {
            return
        }
        self.session.beginConfiguration()
        self.session.removeInput(audioDeviceInput)
        self.session.commitConfiguration()
        self.audioDeviceInput = nil
    }
    
    private func reopenMicrophone() {
        guard self.audioDeviceInput == nil, let audioDevice = self.audioDevice else {
            return
        }
        self.setSelectedAudioDevice(audioDevice)
        if self.audioDeviceInput == nil {
            self.session.stopRunning()
            self.setSelectedAudioDevice(audioDevice)
            self.session.startRunning()
        }
        self.audioConnection = self.audioOutput.connection(with: .audio)
    }
    
    private func continueRecordingAfterResume() {
        if self.isDiscarded {
            return
        }
        switch self.status {
        case .stoppingRecording, .finishRecording, .stopped, .failed:
            return
        default:
            break
        }
        self.configureRecorderTracks()
        self.isPaused = false
        self.renderingEnabled = true
        self.status = .recording
    }
    
    public func resume() {
        VideoRecorderPipeline.queue.async {
            guard self.isPaused else {
                return
            }
            self.clearComposedURL()
            self.liveUploading = nil
            
            let next = temporaryMediaPath("video_message_part", "mp4")
            self.derivedFiles.append(next)
            let nextURL = URL(fileURLWithPath: next)
            self.currentURL = nextURL
            self.recorder = TGVideoCameraMovieRecorder(url: nextURL, delegate: self, callbackQueue: VideoRecorderPipeline.queue.queue)
            if self.audioDevice != nil {
                let previousAudioFormatDescription = self.outputAudioFormatDescription
                self.outputAudioFormatDescription = nil
                self.resumeAfterAudioBuffer = true
                self.reopenMicrophone()
                VideoRecorderPipeline.queue.after(3.0, {
                    guard self.resumeAfterAudioBuffer else {
                        return
                    }
                    self.resumeAfterAudioBuffer = false
                    if self.outputAudioFormatDescription == nil {
                        self.outputAudioFormatDescription = previousAudioFormatDescription
                    }
                    self.continueRecordingAfterResume()
                })
            } else {
                self.continueRecordingAfterResume()
            }
        }
    }
    
    private func finishWithComposedResult() {
        self.composedRecording { [weak self] result in
            guard let self, !self.isDiscarded, case .stoppingRecording = self.status else { return }
            guard let (path, duration) = result, let resultDuration = Int(exactly: ceil(duration)), resultDuration > 0 else {
                self.status = .failed
                return
            }
            self.resultDuration = resultDuration
            let isOriginalFile = self.segments == [self.url]
            if isOriginalFile {
                self.liveUploading?.fileDidChangedSize(true)
            }
            if !self.isDiscarded {
                self.sentPath = path
            }
            self.status = .finishRecording(path: path, duration: self.resultDuration, id: isOriginalFile ? self.liveUploading?.id : nil, thumb: self.thumbnail)
        }
    }

    private func removeUnlessSent(_ path: String) {
        guard path != self.sentPath else {
            return
        }
        removeFile(at: path)
    }

    private func clearComposedURL() {
        compositionRequestId = UUID()
        composeDisposable.set(nil)
        if let composedFile = self.composedFile {
            removeUnlessSent(composedFile)
            self.composedFile = nil
        }
    }

    private func removeSegmentFiles() {
        clearComposedURL()
        for derived in derivedFiles {
            removeUnlessSent(derived)
        }
        derivedFiles = []
    }

    private func removeAllFiles() {
        removeSegmentFiles()
        removeUnlessSent(self.path)
    }
    
    public func applyTrim(_ range: Range<Double>) -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let exportDisposable = MetaDisposable()
            let cancelled = Atomic(value: false)
            VideoRecorderPipeline.queue.async {
                guard !cancelled.with({ $0 }), !self.isDiscarded, self.isPaused else {
                    subscriber.putNext(false)
                    subscriber.putCompletion()
                    return
                }
                self.composedRecording { [weak self] result in
                    guard let self else {
                        subscriber.putNext(false)
                        subscriber.putCompletion()
                        return
                    }
                    guard let (path, _) = result else {
                        subscriber.putNext(false)
                        subscriber.putCompletion()
                        return
                    }
                    guard !cancelled.with({ $0 }), !self.isDiscarded, self.isPaused else {
                        subscriber.putNext(false)
                        subscriber.putCompletion()
                        return
                    }
                    exportDisposable.set(exportTrimmedVideo(path: path, range: range).start(next: { output in
                        VideoRecorderPipeline.queue.async {
                            guard !cancelled.with({ $0 }), !self.isDiscarded, self.isPaused else {
                                output?.discard()
                                subscriber.putNext(false)
                                subscriber.putCompletion()
                                return
                            }
                            if let output, let outputPath = output.takePath() {
                                self.removeSegmentFiles()
                                self.derivedFiles.append(outputPath)
                                self.segments = [URL(fileURLWithPath: outputPath)]
                                self.completedDuration = output.duration
                                self.lastSegmentDuration = 0
                                self.liveUploading = nil
                                self.status = .paused(info: ChatRecordingPreviewData(path: outputPath, duration: self.completedDuration, waveform: nil, thumb: self.thumbnail))
                                subscriber.putNext(true)
                            } else {
                                subscriber.putNext(false)
                            }
                            subscriber.putCompletion()
                        }
                    }))
                }
            }
            return ActionDisposable {
                _ = cancelled.swap(true)
                exportDisposable.dispose()
            }
        }
    }
    
    private func composedRecording(_ completion: @escaping ((String, Double)?) -> Void) {
        let requestId = UUID()
        self.compositionRequestId = requestId
        self.composeDisposable.set(nil)
        let segments = self.segments
        guard !self.isDiscarded, !segments.isEmpty else {
            completion(nil)
            return
        }
        if segments.count == 1, let single = segments.first {
            guard let duration = recordingVideoDuration(AVURLAsset(url: single)) else {
                completion(nil)
                return
            }
            completion((single.path, duration))
            return
        }
        guard let composition = recordingVideoComposition(segments) else {
            completion(nil)
            return
        }
        let request = MetaDisposable()
        composeDisposable.set(request)
        request.set((passthroughExport(asset: composition, name: "video_message_joined") |> then(.single(nil)) |> take(1)).start(next: { [weak self] output in
            VideoRecorderPipeline.queue.async {
                guard let self else {
                    output?.discard()
                    return
                }
                guard self.compositionRequestId == requestId else {
                    output?.discard()
                    return
                }
                guard !self.isDiscarded, self.segments == segments else {
                    output?.discard()
                    completion(nil)
                    return
                }
                guard let output, output.duration.isFinite, output.duration > 0,
                    Int(exactly: ceil(output.duration)) != nil, let outputPath = output.takePath() else {
                    output?.discard()
                    completion(nil)
                    return
                }
                self.clearComposedURL()
                self.composedFile = outputPath
                completion((outputPath, output.duration))
            }
        }))
    }


    
    private func observeCaptureInterruptions() {
        let queue = VideoRecorderPipeline.queue
        self.deviceObservers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil, using: { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.audio) else {
                return
            }
            let uniqueID = device.uniqueID
            queue.async {
                self?.audioDeviceWasDisconnected(uniqueID: uniqueID)
            }
        }))
        self.deviceObservers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: self.session, queue: nil, using: { [weak self] _ in
            queue.async {
                guard let self, !self.isDiscarded else {
                    return
                }
                switch self.status {
                case .stoppingRecording, .finishRecording, .stopped, .failed:
                    return
                default:
                    self.session.startRunning()
                }
            }
        }))
    }
    
    private func audioDeviceWasDisconnected(uniqueID: String) {
        guard !self.isDiscarded, self.audioDevice?.uniqueID == uniqueID else {
            return
        }
        let fallback = AVCaptureDevice.default(for: .audio).flatMap { $0.uniqueID != uniqueID && $0.isConnected && !$0.isSuspended ? $0 : nil } ?? AVCaptureDevice.devices(for: .audio).first(where: { $0.uniqueID != uniqueID && $0.isConnected && !$0.isSuspended })
        guard let fallback else {
            return
        }
        if self.audioDeviceInput == nil {
            self.audioDevice = fallback
            return
        }
        self.setSelectedAudioDevice(fallback)
        self.audioConnection = self.audioOutput.connection(with: .audio)
    }
    
    deinit {
        for observer in self.deviceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        VideoRecorderPipeline.queue.sync {
            stopCapture()
            removeAllFiles()
        }
        composeDisposable.dispose()
    }

    
    public func stop() {
        VideoRecorderPipeline.queue.async {
            if case .finishRecording = self.status {
                return
            }
            self.status = .stoppingRecording
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            if self.isPaused {
                if self.completedDuration >= 0.5 {
                    self.finishWithComposedResult()
                } else {
                    self.dispose()
                }
                return
            }
            
            self.lastSegmentDuration = self.currentSegmentDuration
            if self.completedDuration + self.lastSegmentDuration >= 0.5 {
                self.recorder.finishRecording()
            } else {
                self.dispose()
            }
        }
    }
    
    public func stopCapture() {
        VideoRecorderPipeline.queue.async {
            self.session.stopRunning()
        }
    }
    
    public func dispose() {
        VideoRecorderPipeline.queue.async {
            self.isDiscarded = true
            self.sentPath = nil
            if case .finishRecording = self.status {
                return
            }
            self.status = .stopped(thumb: self.thumbnail)
            self.lastSegmentDuration = self.currentSegmentDuration
            self.resultDuration = Int(ceil(self.completedDuration + self.lastSegmentDuration))
        }
    }
  
    
    public func start() {
        VideoRecorderPipeline.queue.async {
            self.status = .startingRecording
            self.session.startRunning()
        }
    }
}
