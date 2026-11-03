import AVFoundation

public final class VoiceRecorderInputConverter {
    public static let outputSampleRate: Double = 48000

    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var outputBuffer: AVAudioPCMBuffer?

    public init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            return nil
        }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: VoiceRecorderInputConverter.outputSampleRate, channels: 1, interleaved: true) else {
            return nil
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    private func outputBuffer(forInputFrames frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount((Double(frames) * self.outputFormat.sampleRate / self.inputFormat.sampleRate).rounded(.up)) + 1024
        if let buffer = self.outputBuffer, buffer.frameCapacity >= capacity {
            buffer.frameLength = 0
            return buffer
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: capacity)
        self.outputBuffer = buffer
        return buffer
    }

    private func run(input: AVAudioPCMBuffer?, frames: AVAudioFrameCount, output: (UnsafePointer<Int16>, Int) -> Void) {
        var provided = false
        while true {
            guard let buffer = self.outputBuffer(forInputFrames: frames) else {
                return
            }
            var error: NSError?
            let status = self.converter.convert(to: buffer, error: &error, withInputFrom: { _, inputStatus in
                if let input = input, !provided {
                    provided = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            })
            if buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] {
                output(samples, Int(buffer.frameLength))
            }
            if status != .haveData || buffer.frameLength == 0 {
                break
            }
        }
    }

    public func convert(_ buffer: AVAudioPCMBuffer, output: (UnsafePointer<Int16>, Int) -> Void) {
        guard buffer.frameLength > 0 else {
            return
        }
        self.run(input: buffer, frames: buffer.frameLength, output: output)
    }

    public func flush(output: (UnsafePointer<Int16>, Int) -> Void) {
        self.run(input: nil, frames: 4096, output: output)
        self.converter.reset()
    }
}

public final class VoiceRecorderPacketizer {
    public static let packetSamples = 960

    private let packet: UnsafeMutablePointer<Int16>
    public private(set) var pendingSamples: Int = 0

    public init() {
        self.packet = UnsafeMutablePointer<Int16>.allocate(capacity: VoiceRecorderPacketizer.packetSamples)
        self.packet.initialize(repeating: 0, count: VoiceRecorderPacketizer.packetSamples)
    }

    deinit {
        self.packet.deallocate()
    }

    public func append(_ samples: UnsafePointer<Int16>, count: Int, packet: (UnsafePointer<Int16>, Int) -> Void) {
        var offset = 0
        while offset < count {
            let taken = min(count - offset, VoiceRecorderPacketizer.packetSamples - self.pendingSamples)
            self.packet.advanced(by: self.pendingSamples).update(from: samples.advanced(by: offset), count: taken)
            self.pendingSamples += taken
            offset += taken
            if self.pendingSamples == VoiceRecorderPacketizer.packetSamples {
                packet(UnsafePointer(self.packet), VoiceRecorderPacketizer.packetSamples)
                self.pendingSamples = 0
            }
        }
    }
}
