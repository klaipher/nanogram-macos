import AVFoundation
import CoreAudio

public enum VoiceRecorderAudioEngineError: Error {
    case noInputDevice
    case unsupportedFormat
}

public final class VoiceRecorderAudioEngine {
    private let engine = AVAudioEngine()
    private let inputDeviceUID: String?
    private let voiceProcessing: Bool
    private var configured = false
    private var tapInstalled = false

    public init(inputDeviceUID: String?, voiceProcessing: Bool) {
        self.inputDeviceUID = inputDeviceUID
        self.voiceProcessing = voiceProcessing
    }

    deinit {
        self.stop()
    }

    public static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else {
            return nil
        }
        return device
    }

    public static func device(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var uid = uid as CFString
        let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else {
            return nil
        }
        return device
    }

    public static func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else {
            return nil
        }
        return rate
    }

    private func configure() {
        guard !self.configured else {
            return
        }
        self.configured = true
        let input = self.engine.inputNode
        if let uid = self.inputDeviceUID, let device = VoiceRecorderAudioEngine.device(uid: uid), let audioUnit = input.audioUnit {
            var device = device
            AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        if self.voiceProcessing, #available(macOS 10.15, *) {
            do {
                try input.setVoiceProcessingEnabled(true)
                if #available(macOS 14.0, *) {
                    input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch {
            }
        }
    }

    public func prepare() {
        self.configure()
        self.engine.prepare()
    }

    public var inputFormat: AVAudioFormat {
        self.configure()
        return self.engine.inputNode.outputFormat(forBus: 0)
    }

    public func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.configure()
        if self.inputDeviceUID == nil, VoiceRecorderAudioEngine.defaultInputDevice() == nil {
            throw VoiceRecorderAudioEngineError.noInputDevice
        }
        let input = self.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceRecorderAudioEngineError.unsupportedFormat
        }
        if self.tapInstalled {
            input.removeTap(onBus: 0)
        }
        let bufferSize = AVAudioFrameCount(max(256, (format.sampleRate * 0.02).rounded()))
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: { buffer, _ in
            onBuffer(buffer)
        })
        self.tapInstalled = true
        self.engine.prepare()
        do {
            try self.engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.tapInstalled = false
            throw error
        }
    }

    public func stop() {
        if self.tapInstalled {
            self.engine.inputNode.removeTap(onBus: 0)
            self.tapInstalled = false
        }
        if self.engine.isRunning {
            self.engine.stop()
        }
    }
}
