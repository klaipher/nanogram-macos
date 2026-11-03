import Foundation
import AVFoundation
import SwiftSignalKit
import TelegramCore
import InAppSettings
import Postbox
import TelegramMedia
import TelegramMediaUtils
import SystemPermissions
import VoiceRecorderInput



private let queue = Queue(name: "micro-listen", qos: .background)

private final class MicroListenerContextObject {
    private let devicesDisposable = MetaDisposable()
    private let devices: DevicesContext
    private let accountManager: AccountManager<TelegramAccountManagerTypes>
    
    
    private var device: AVCaptureDevice?
    private var engine: VoiceRecorderAudioEngine?
    private var converter: VoiceRecorderInputConverter?
    private var inputGeneration: Int = 0

    
    private var onSpeaking:((Float)->Void)?
    private var always: Bool = false
    
    private var paused: Bool = true
    
    private var stack:[Float] = [] {
        didSet {
            if stack.count >= 70, onSpeaking != nil {
                onSpeaking?(stack.last!)
                onSpeaking = nil
                pause()
            }
        }
    }
    private var micLevelPeak: Int16 = 0
    private var micLevelPeakCount: Int = 0

    private let queue: Queue
    
    public init(queue: Queue, devices:DevicesContext, accountManager: AccountManager<TelegramAccountManagerTypes>) {
        self.devices = devices
        self.queue = queue
        self.accountManager = accountManager
    }
    
    deinit {
        stop()
        devicesDisposable.dispose()
    }
    
    public func pause() {
        if !paused {
            paused = true
            devicesDisposable.set(nil)
            self.stop()
        }
    }
    public func resume(onSpeaking: @escaping(Float)->Void, always: Bool) {
        if paused {
            paused = false
            self.always = always
            self.onSpeaking = onSpeaking
            let signal = combineLatest(queue: queue, devices.signal, voiceCallSettings(accountManager), requestMicrophonePermission())
            
            devicesDisposable.set(signal.start(next: { [weak self] devices, settings, permission in
                let device = settings.audioInputDeviceId == nil ? devices.audioInput.first : devices.audioInput.first(where: { $0.uniqueID == settings.audioInputDeviceId })

                if let device = device, permission {
                    self?.start(device)
                } else {
                    self?.stop()
                }
            }))
        }
    }
    
    
    private func start(_ device: AVCaptureDevice) {
        if self.device != device {
            self.device = device
            
            
            self.stopEngine()
            
            let engine = VoiceRecorderAudioEngine(inputDeviceUID: device.uniqueID, voiceProcessing: false)
            self.engine = engine
            guard let converter = VoiceRecorderInputConverter(inputFormat: engine.inputFormat) else {
                return
            }
            self.converter = converter
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
                self.stop()
            }
        }
    }
    
    private func stopEngine() {
        self.inputGeneration += 1
        self.engine?.stop()
        self.engine = nil
        self.converter = nil
    }
    
    public func stop() {
        device = nil
        assert(queue.isCurrent())
        
        
        self.paused = true
        
        self.stopEngine()
    }
    
    private func processInput(_ buffer: AVAudioPCMBuffer, generation: Int) {
        assert(queue.isCurrent())
        guard generation == self.inputGeneration, let converter = self.converter else {
            return
        }
        converter.convert(buffer) { samples, count in
            self.processWaveformPreview(samples: samples, count: count)
        }
    }

    private func processWaveformPreview(samples: UnsafePointer<Int16>, count: Int) {
        for i in 0 ..< count {
            var sample = samples.advanced(by: i).pointee
            if sample < 0 {
                if sample == Int16.min {
                    sample = Int16.max
                } else {
                    sample = -sample
                }
            }
            
            if self.micLevelPeak < sample {
                self.micLevelPeak = sample
            }
            self.micLevelPeakCount += 1
            
            if self.micLevelPeakCount >= 1200 {
                let level = Float(self.micLevelPeak) / 4000.0
                if always {
                    self.onSpeaking?(level)
                } else {
                    if level >= 0.4 {
                        self.stack.append(level)
                    }
                }
               
                self.micLevelPeak = 0
                self.micLevelPeakCount = 0
            }
        }
    }
    
}


public final class MicroListenerContext {
    private let contextRef: QueueLocalObject<MicroListenerContextObject>
    public init(devices:DevicesContext, accountManager: AccountManager<TelegramAccountManagerTypes>) {
        contextRef = .init(queue: queue, generate: {
            return MicroListenerContextObject(queue: queue, devices: devices, accountManager: accountManager)
        })
    }
    
    deinit {
        contextRef.syncWith({
            $0.stop()
        })
    }
    
    public func pause() {
        contextRef.syncWith {
            $0.pause()
        }
    }
    public func resume(onSpeaking: @escaping(Float)->Void, always: Bool = false) {
        contextRef.syncWith {
            $0.resume(onSpeaking: { value in
                DispatchQueue.main.async {
                    onSpeaking(value)
                }
            }, always: always)
        }
    }

}

