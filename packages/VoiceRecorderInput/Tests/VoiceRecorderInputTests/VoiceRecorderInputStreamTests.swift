import XCTest
import AVFoundation
@testable import VoiceRecorderInput

final class VoiceRecorderInputStreamTests: XCTestCase {
    private func tone(sampleRate: Double, frequency: Double, seconds: Double, startFrame: Int = 0) -> [AVAudioPCMBuffer] {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let total = Int(sampleRate * seconds)
        let chunk = Int(sampleRate * 0.02)
        var result: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < total {
            let count = min(chunk, total - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0 ..< count {
                buffer.floatChannelData![0][i] = Float(0.5 * sin(2.0 * Double.pi * frequency * Double(startFrame + offset + i) / sampleRate))
            }
            result.append(buffer)
            offset += count
        }
        return result
    }

    private func power(_ samples: ArraySlice<Int16>, frequency: Double) -> Double {
        let coefficient = 2.0 * cos(2.0 * Double.pi * frequency / 48000.0)
        var s1 = 0.0
        var s2 = 0.0
        for sample in samples {
            let s0 = Double(sample) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        return s1 * s1 + s2 * s2 - coefficient * s1 * s2
    }

    func testARateChangeMidNoteKeepsPitchAndDuration() {
        let stream = VoiceRecorderInputStream()
        var output: [Int16] = []
        var packets = 0
        let sink: (UnsafePointer<Int16>, Int) -> Void = { samples, count in
            output.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
            packets += 1
        }
        for buffer in self.tone(sampleRate: 48000, frequency: 1000, seconds: 1.0) {
            stream.process(buffer, packet: sink)
        }
        for buffer in self.tone(sampleRate: 24000, frequency: 1000, seconds: 1.0) {
            stream.process(buffer, packet: sink)
        }
        stream.finish(packet: sink)

        XCTAssertEqual(Double(output.count), 96000, accuracy: 960)
        XCTAssertTrue(output.count % VoiceRecorderPacketizer.packetSamples == 0)
        let firstHalf = output[4800 ..< 43200]
        let secondHalf = output[52800 ..< min(91200, output.count)]
        for half in [firstHalf, secondHalf] {
            XCTAssertGreaterThan(self.power(half, frequency: 1000), 50.0 * self.power(half, frequency: 500))
            XCTAssertGreaterThan(self.power(half, frequency: 1000), 50.0 * self.power(half, frequency: 2000))
        }
    }

    func testTheConverterIsRebuiltOnlyWhenTheFormatChanges() {
        let stream = VoiceRecorderInputStream()
        let sink: (UnsafePointer<Int16>, Int) -> Void = { _, _ in }
        for buffer in self.tone(sampleRate: 48000, frequency: 440, seconds: 0.2) {
            stream.process(buffer, packet: sink)
        }
        XCTAssertEqual(stream.converterGeneration, 1)
        for buffer in self.tone(sampleRate: 16000, frequency: 440, seconds: 0.2) {
            stream.process(buffer, packet: sink)
        }
        XCTAssertEqual(stream.converterGeneration, 2)
    }
}
