import Cocoa
import OpusBinding
import Foundation
import SwiftSignalKit
import CoreMedia
import AVFoundation
import TelegramCore
import VoiceRecorderInput

private let opusDecodedSampleRate: Int = 48000
private let opusFrameSamples: Int = 960

public func temporaryMediaPath(_ name: String, _ ext: String) -> String {
    return NSTemporaryDirectory() + name + "_" + UUID().uuidString + "." + ext
}

public func trimOpusFile(_ path: String, to outputPath: String, start: Double, end: Double) -> Bool {
    guard start.isFinite, end.isFinite, start >= 0, end > start,
        let startSample = Int(exactly: (start * Double(opusDecodedSampleRate)).rounded()),
        let endSample = Int(exactly: (end * Double(opusDecodedSampleRate)).rounded()),
        endSample > startSample, let reader = OggOpusReader(path: path) else {
        return false
    }
    let outputURL = URL(fileURLWithPath: outputPath)
    do {
        try Data().write(to: outputURL, options: .withoutOverwriting)
    } catch {
        return false
    }
    var succeeded = false
    defer {
        if !succeeded {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    let dataItem = DataItem(path: outputPath)
    let writer = TGOggOpusWriter()
    guard writer.begin(with: dataItem) else {
        return false
    }

    let readCapacity = opusFrameSamples * 8

    let readBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: readCapacity)
    let frame = UnsafeMutablePointer<Int16>.allocate(capacity: opusFrameSamples)
    defer {
        readBuffer.deallocate()
        frame.deallocate()
    }
    frame.initialize(repeating: 0, count: opusFrameSamples)

    func writeFrame(samples: Int) -> Bool {
        return writer.writeFrame(UnsafeMutableRawPointer(frame).assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(samples * 2))
    }

    var framePos = 0
    var cursor = 0
    var copiedSamples = 0

    decoding: while cursor < endSample {
        let decoded = reader.read(UnsafeMutableRawPointer(readBuffer), bufSize: Int32(readCapacity))
        if decoded < 0 || decoded > readCapacity {
            return false
        }
        if decoded == 0 {
            break
        }
        for i in 0 ..< Int(decoded) {
            let index = cursor + i
            if index < startSample {
                continue
            }
            if index >= endSample {
                break decoding
            }
            frame[framePos] = readBuffer[i]
            framePos += 1
            copiedSamples += 1
            if framePos == opusFrameSamples {
                guard writeFrame(samples: opusFrameSamples) else { return false }
                framePos = 0
            }
        }
        cursor += Int(decoded)
    }

    if framePos > 0 {
        guard writeFrame(samples: framePos) else { return false }
    }

    guard copiedSamples == endSample - startSample, writer.writeFrame(nil, frameByteCount: 0),
        let writtenData = try? Data(contentsOf: outputURL), writtenData == dataItem.data() else {
        return false
    }

    succeeded = true
    return true
}

public struct RecordedAudioData {
    public let compressedData: Data
    public let duration: Double
    public let waveform: Data?
    public let displayWaveform: AudioWaveform?
    public let id:Int64?
    public let path: String
    public init(compressedData: Data, duration: Double, waveform: Data?, displayWaveform: AudioWaveform? = nil, id: Int64?, path: String) {
        self.compressedData = compressedData
        self.duration = duration
        self.waveform = waveform
        self.displayWaveform = displayWaveform
        self.id = id
        self.path = path
    }
}


final class ManagedAudioRecorderContext {
    private let micLevel: ValuePromise<Float>
    private let recordingState: ValuePromise<AudioRecordingState>
    private var liveUploading:PreUploadManager?
    private var paused = true
    
    private let queue: Queue
    private var oggWriter: TGOggOpusWriter
    private var dataItem: DataItem
    private let inputDeviceUID: String?
    private let voiceProcessing: Bool
    private var engine: VoiceRecorderAudioEngine?
    private let inputStream = VoiceRecorderInputStream()
    private var inputGeneration: Int = 0
    
    private var waveformSamples = Data()
    private var waveformPeak: Int16 = 0
    private var waveformPeakCount: Int = 0
    
    private var micLevelPeak: Int16 = 0
    private var micLevelPeakCount: Int = 0
    
    private var encoderState: [AnyHashable : Any]?
    
    private var recordingStateUpdateTimestamp: Double?
    
    
    init(queue: Queue, micLevel: ValuePromise<Float>, recordingState: ValuePromise<AudioRecordingState>, liveUploading: PreUploadManager?, dataItem: DataItem, inputDeviceUID: String?, voiceProcessing: Bool) {
        assert(queue.isCurrent())
        self.liveUploading = liveUploading
        self.inputDeviceUID = inputDeviceUID
        self.voiceProcessing = voiceProcessing
        self.micLevel = micLevel
        self.recordingState = recordingState
        
        self.queue = queue
        self.dataItem = dataItem
        self.oggWriter = TGOggOpusWriter()
        
        self.oggWriter.begin(with: self.dataItem)
    }
    
    deinit {
        assert(self.queue.isCurrent())
        
        self.stop()
        
    }
    
    func start() {
        assert(self.queue.isCurrent())
        
        self.paused = false
        
        let engine: VoiceRecorderAudioEngine
        if let current = self.engine {
            engine = current
        } else {
            engine = VoiceRecorderAudioEngine(inputDeviceUID: self.inputDeviceUID, voiceProcessing: self.voiceProcessing)
            let queue = self.queue
            engine.onConfigurationChange = { [weak self] in
                queue.async {
                    self?.restartAfterConfigurationChange()
                }
            }
            self.engine = engine
        }
        guard VoiceRecorderInputConverter(inputFormat: engine.inputFormat) != nil else {
            trace1("ManagedAudioRecorder", what: "unsupported input format \(engine.inputFormat)")
            self.failToStart()
            return
        }
        self.inputGeneration += 1
        let generation = self.inputGeneration
        let queue = self.queue
        do {
            try engine.start { [weak self] buffer in
                guard let copy = buffer.copy() as? AVAudioPCMBuffer else {
                    return
                }
                queue.async {
                    self?.processInput(copy, generation: generation)
                }
            }
        } catch {
            trace1("ManagedAudioRecorder", what: "input engine failed to start: \(error)")
            self.failToStart()
            return
        }
        self.recordingState.set(.recording(duration: self.oggWriter.encodedDuration(), durationMediaTimestamp: CACurrentMediaTime()))
    }
    
    private func failToStart() {
        self.inputGeneration += 1
        self.engine?.stop()
        self.paused = true
        self.recordingStateUpdateTimestamp = nil
        self.recordingState.set(.paused(duration: self.oggWriter.encodedDuration()))
    }
    
    private func restartAfterConfigurationChange() {
        assert(self.queue.isCurrent())
        guard !self.paused else {
            return
        }
        trace1("ManagedAudioRecorder", what: "input configuration changed, restarting")
        self.tearDownAudioUnit()
        self.start()
    }
    
    private func processInput(_ buffer: AVAudioPCMBuffer, generation: Int) {
        assert(self.queue.isCurrent())
        guard generation == self.inputGeneration, !self.paused else {
            return
        }
        self.inputStream.process(buffer) { packet, count in
            self.writePacket(packet, count: count)
        }
    }
    
    private func writePacket(_ packet: UnsafePointer<Int16>, count: Int) {
        self.processWaveformPreview(samples: packet, count: count)
        self.oggWriter.writeFrame(UnsafeMutableRawPointer(mutating: packet).assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(count * 2))
        self.liveUploading?.fileDidChangedSize(false)
        let timestamp = CACurrentMediaTime()
        if self.recordingStateUpdateTimestamp == nil || self.recordingStateUpdateTimestamp! + 0.1 < timestamp {
            self.recordingStateUpdateTimestamp = timestamp
            self.recordingState.set(.recording(duration: self.oggWriter.encodedDuration(), durationMediaTimestamp: timestamp))
        }
    }

    
    func stop() {
        assert(self.queue.isCurrent())

        self.paused = true
        self.tearDownAudioUnit()
    }

    func discard() {
        assert(self.queue.isCurrent())

        self.stop()
        self.liveUploading = nil
        try? FileManager.default.removeItem(atPath: self.dataItem.path)
    }
    
    private func tearDownAudioUnit() {
        self.inputGeneration += 1
        self.engine?.stop()
        self.inputStream.finish { packet, count in
            self.writePacket(packet, count: count)
        }
    }
    
    func pause() {
        assert(self.queue.isCurrent())
        
        guard !self.paused else {
            return
        }
        
        self.paused = true
        self.tearDownAudioUnit()
        self.encoderState = self.oggWriter.pause()
        self.liveUploading?.fileDidChangedSize(false)
        self.recordingStateUpdateTimestamp = nil
        self.recordingState.set(.paused(duration: self.oggWriter.encodedDuration()))
    }
    
    func resume() {
        assert(self.queue.isCurrent())
        
        guard self.paused else {
            return
        }
        
        self.encoderState = nil
        self.recordingStateUpdateTimestamp = nil
        self.start()
    }
    
    func applyTrim(_ range: Range<Double>) -> Bool {
        assert(self.queue.isCurrent())

        let duration = self.oggWriter.encodedDuration()
        guard self.paused, duration.isFinite, duration > 0, range.lowerBound.isFinite, range.upperBound.isFinite,
            range.lowerBound >= 0, range.lowerBound < range.upperBound, range.upperBound <= duration else {
            return false
        }
        guard range.lowerBound > 0 || range.upperBound < duration else {
            return true
        }
        let encoderState = self.oggWriter.pause()
        guard !encoderState.isEmpty else { return false }
        self.encoderState = encoderState
        let trimmedPath = temporaryMediaPath("voice_trim", "ogg")
        let sourcePath = temporaryMediaPath("voice_trim_source", "ogg")
        defer {
            try? FileManager.default.removeItem(atPath: trimmedPath)
            try? FileManager.default.removeItem(atPath: sourcePath)
        }
        var trimSource = self.dataItem.path
        if encoderState["finished"] as? Bool != true {
            let sourceItem = DataItem(path: sourcePath, initialData: self.dataItem.data())
            let sourceWriter = TGOggOpusWriter()
            guard sourceWriter.resume(with: sourceItem, encoderState: encoderState) else { return false }
            do {
                try sourceItem.data().write(to: URL(fileURLWithPath: sourcePath), options: .withoutOverwriting)
            } catch {
                return false
            }
            guard sourceWriter.writeFrame(nil, frameByteCount: 0) else { return false }
            trimSource = sourcePath
        }
        guard trimOpusFile(trimSource, to: trimmedPath, start: range.lowerBound, end: range.upperBound),
            let trimmed = try? Data(contentsOf: URL(fileURLWithPath: trimmedPath)),
            self.replaceStore(with: trimmed) else {
            return false
        }
        self.trimWaveformSamples(from: range.lowerBound / duration, to: range.upperBound / duration)
        self.recordingStateUpdateTimestamp = nil
        self.recordingState.set(.paused(duration: self.oggWriter.encodedDuration()))

        return true
    }

    private func replaceStore(with trimmed: Data) -> Bool {
        guard !trimmed.isEmpty else { return false }
        let dataItem = DataItem(path: self.dataItem.path, initialData: trimmed)
        let oggWriter = TGOggOpusWriter()
        guard oggWriter.beginAppend(with: dataItem) else {
            return false
        }
        do {
            try trimmed.write(to: URL(fileURLWithPath: dataItem.path), options: .atomic)
        } catch {
            return false
        }
        self.dataItem = dataItem
        self.oggWriter = oggWriter
        self.encoderState = nil
        self.liveUploading = nil
        return true
    }
    
    private func trimWaveformSamples(from start: Double, to end: Double) {
        guard !self.waveformSamples.isEmpty else {
            return
        }
        self.waveformSamples = AudioWaveform(samples: self.waveformSamples, peak: 0).subwaveform(from: start, to: end).samples
        self.waveformPeak = 0
        self.waveformPeakCount = 0
    }
    
    func processWaveformPreview(samples: UnsafePointer<Int16>, count: Int) {
        for i in 0 ..< count {
            var sample = samples.advanced(by: i).pointee
            if sample < 0 {
                if sample == Int16.min {
                    sample = Int16.max
                } else {
                    sample = -sample
                }
            }
            if self.waveformPeak < sample {
                self.waveformPeak = sample
            }
            self.waveformPeakCount += 1
            
            if self.waveformPeakCount >= 100 {
                var waveformPeak = self.waveformPeak
                withUnsafeBytes(of: &waveformPeak, { bytes -> Void in
                    self.waveformSamples.append(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 2)
                })
                self.waveformPeak = 0
                self.waveformPeakCount = 0
            }
            
            if self.micLevelPeak < sample {
                self.micLevelPeak = sample
            }
            self.micLevelPeakCount += 1
            
            if self.micLevelPeakCount >= 1200 {
                let level = Float(self.micLevelPeak) / 4000.0
                self.micLevel.set(level)
                self.micLevelPeak = 0
                self.micLevelPeakCount = 0
            }
        }
    }
    
    private func makeWaveformBitstream() -> Data? {
        return self.makeDisplayWaveform(buckets: 100)?.makeBitstream()
    }

    private func makeDisplayWaveform(buckets: Int = 400) -> AudioWaveform? {
        let sourceCount = self.waveformSamples.count / 2
        guard sourceCount > 0 else {
            return nil
        }
        let count = min(buckets, sourceCount)
        var result = Data(count: count * 2)
        var sumSamples: Int64 = 0

        self.waveformSamples.withUnsafeBytes { (samples: UnsafePointer<Int16>) -> Void in
            result.withUnsafeMutableBytes { (destination: UnsafeMutablePointer<Int16>) -> Void in
                for i in 0 ..< count {
                    let start = i * sourceCount / count
                    let end = min(sourceCount, max(start + 1, (i + 1) * sourceCount / count))
                    var bucketPeak: Int16 = 0
                    for j in start ..< end {
                        bucketPeak = max(bucketPeak, samples[j])
                    }
                    destination[i] = bucketPeak
                    sumSamples += Int64(bucketPeak)
                }
            }
        }

        guard sumSamples > 0 else {
            return nil
        }

        var calculatedPeak = UInt16(Double(sumSamples) * 1.8 / Double(count))
        if calculatedPeak < 2500 {
            calculatedPeak = 2500
        }
        let ceiling = Int16(clamping: Int64(calculatedPeak))

        result.withUnsafeMutableBytes { (destination: UnsafeMutablePointer<Int16>) -> Void in
            for i in 0 ..< count {
                destination[i] = min(destination[i], ceiling)
            }
        }

        return AudioWaveform(samples: result, peak: Int32(ceiling))
    }

    func takeData() -> RecordedAudioData? {
        guard self.oggWriter.writeFrame(nil, frameByteCount: 0) else {
            return nil
        }
        let waveform = self.makeWaveformBitstream()
        liveUploading?.fileDidChangedSize(true)
        return self.snapshot(waveform: waveform, displayWaveform: nil)
    }

    func takePreviewData() -> RecordedAudioData? {
        let duration = self.oggWriter.encodedDuration()
        guard duration > 0 else {
            return nil
        }
        return self.snapshot(waveform: self.makeWaveformBitstream(), displayWaveform: self.makeDisplayWaveform())
    }

    private func snapshot(waveform: Data?, displayWaveform: AudioWaveform?) -> RecordedAudioData {
        return RecordedAudioData(compressedData: self.dataItem.data(), duration: self.oggWriter.encodedDuration(), waveform: waveform, displayWaveform: displayWaveform, id: self.liveUploading?.id, path: self.dataItem.path)
    }
}

public enum AudioRecordingState: Equatable {
    case paused(duration: Double)
    case recording(duration: Double, durationMediaTimestamp: Double)
    
    public static func ==(lhs: AudioRecordingState, rhs: AudioRecordingState) -> Bool {
        switch lhs {
        case let .paused(duration):
            if case .paused(duration) = rhs {
                return true
            } else {
                return false
            }
        case let .recording(duration, durationMediaTimestamp):
            if case .recording(duration, durationMediaTimestamp) = rhs {
                return true
            } else {
                return false
            }
        }
    }
}

public final class ManagedAudioRecorder {
    private let queue = Queue()
    private var contextRef: Unmanaged<ManagedAudioRecorderContext>?
    private let micLevelValue = ValuePromise<Float>(0.0)
    private let recordingStateValue = ValuePromise<AudioRecordingState>(.paused(duration: 0.0))
    public var micLevel: Signal<Float, NoError> {
        return self.micLevelValue.get()
    }
    
    public var recordingState: Signal<AudioRecordingState, NoError> {
        return self.recordingStateValue.get()
    }
    
    public init(liveUploading: PreUploadManager?, dataItem: DataItem, inputDeviceUID: String? = nil, voiceProcessing: Bool = false) {
        
        self.queue.async {
            let context = ManagedAudioRecorderContext(queue: self.queue, micLevel: self.micLevelValue, recordingState: self.recordingStateValue, liveUploading: liveUploading, dataItem: dataItem, inputDeviceUID: inputDeviceUID, voiceProcessing: voiceProcessing)
            self.contextRef = Unmanaged.passRetained(context)
        }
    }
    
    public func start() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.start()
            }
        }
    }
    
    public func stop() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.stop()
            }
        }
    }
    
    private func perform(_ f: @escaping (ManagedAudioRecorderContext) -> Void) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                f(context)
            }
        }
    }

    private func query<T>(_ fallback: T, _ f: @escaping (ManagedAudioRecorderContext) -> T) -> Signal<T, NoError> {
        return Signal { subscriber in
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    subscriber.putNext(f(context))
                } else {
                    subscriber.putNext(fallback)
                }
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    public func pause() {
        self.perform { $0.pause() }
    }
    
    public func resume() {
        self.perform { $0.resume() }
    }
    
    public func discard() {
        self.perform { $0.discard() }
    }

    public func applyTrim(_ range: Range<Double>) -> Signal<Bool, NoError> {
        return self.query(false) { $0.applyTrim(range) }
    }
    
    public func previewData() -> Signal<RecordedAudioData?, NoError> {
        return self.query(nil) { $0.takePreviewData() }
    }
    
    public func takenRecordedData() -> Signal<RecordedAudioData?, NoError> {
        return Signal { subscriber in
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    subscriber.putNext(context.takeData())
                    subscriber.putCompletion()
                } else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                }
            }
            return EmptyDisposable
        }
    }
    
    deinit {
        let contextRef = self.contextRef
        self.queue.async {
            contextRef?.release()
        }
    }
}
