import XCTest
import AVFoundation
import Accelerate
import CoreAudio
import OpusBinding
@testable import VoiceRecorderInput

final class VoiceRecorderInputTests: XCTestCase {
    private func sineBuffer(sampleRate: Double, channels: AVAudioChannelCount, frequency: Double, seconds: Double, interleaved: Bool = false, commonFormat: AVAudioCommonFormat = .pcmFormatFloat32) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate, channels: channels, interleaved: interleaved)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0 ..< Int(frames) {
            let value = 0.5 * sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate)
            for channel in 0 ..< Int(channels) {
                switch commonFormat {
                case .pcmFormatFloat32:
                    if interleaved {
                        buffer.floatChannelData![0][frame * Int(channels) + channel] = Float(value)
                    } else {
                        buffer.floatChannelData![channel][frame] = Float(value)
                    }
                case .pcmFormatInt16:
                    buffer.int16ChannelData![channel][frame] = Int16(value * 32767)
                default:
                    XCTFail()
                }
            }
        }
        return buffer
    }

    private func slices(of buffer: AVAudioPCMBuffer, sizes: [Int]) -> [AVAudioPCMBuffer] {
        var result: [AVAudioPCMBuffer] = []
        var offset = 0
        var index = 0
        let total = Int(buffer.frameLength)
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        while offset < total {
            let count = min(sizes[index % sizes.count], total - offset)
            index += 1
            let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count))!
            slice.frameLength = AVAudioFrameCount(count)
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
            for i in 0 ..< source.count {
                memcpy(target[i].mData!, source[i].mData!.advanced(by: offset * bytesPerFrame), count * bytesPerFrame)
            }
            result.append(slice)
            offset += count
        }
        return result
    }

    private func dominantFrequency(_ samples: [Int16], sampleRate: Double) -> Double {
        let n = 32768
        let start = max(0, (samples.count - n) / 2)
        var real = [Float](repeating: 0, count: n)
        for i in 0 ..< min(n, samples.count - start) {
            real[i] = Float(samples[start + i]) / 32768.0
        }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(real, 1, window, 1, &real, 1, vDSP_Length(n))
        var imaginary = [Float](repeating: 0, count: n)
        let log2n = vDSP_Length(log2(Float(n)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        var maxValue: Float = 0
        var maxIndex: vDSP_Length = 0
        vDSP_maxvi(magnitudes, 1, &maxValue, &maxIndex, vDSP_Length(n / 2))
        return Double(maxIndex) * sampleRate / Double(n)
    }

    private func encodeAndDecode(_ buffers: [AVAudioPCMBuffer]) throws -> (samples: [Int16], packets: Int, encodedDuration: Double) {
        let converter = try XCTUnwrap(VoiceRecorderInputConverter(inputFormat: buffers[0].format))
        let packetizer = VoiceRecorderPacketizer()
        let path = NSTemporaryDirectory() + "voice-input-\(UUID().uuidString).ogg"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let dataItem = TGDataItem(data: Data())!
        let writer = TGOggOpusWriter()
        XCTAssertTrue(writer.begin(with: dataItem))
        var packets = 0
        let write: (UnsafePointer<Int16>, Int) -> Void = { pointer, count in
            XCTAssertEqual(count, VoiceRecorderPacketizer.packetSamples)
            packets += 1
            XCTAssertTrue(writer.writeFrame(UnsafeMutableRawPointer(mutating: pointer).assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(count * 2)))
        }
        for buffer in buffers {
            converter.convert(buffer) { pointer, count in
                packetizer.append(pointer, count: count, packet: write)
            }
        }
        converter.flush { pointer, count in
            packetizer.append(pointer, count: count, packet: write)
        }
        let encodedDuration = writer.encodedDuration()
        XCTAssertTrue(writer.writeFrame(nil, frameByteCount: 0))
        try dataItem.data().write(to: URL(fileURLWithPath: path))
        let reader = try XCTUnwrap(OggOpusReader(path: path))
        var decoded: [Int16] = []
        var chunk = [Int16](repeating: 0, count: 960 * 8)
        while true {
            let read = chunk.withUnsafeMutableBytes { reader.read($0.baseAddress!, bufSize: Int32(960 * 8)) }
            if read <= 0 { break }
            decoded.append(contentsOf: chunk[0 ..< Int(read)])
        }
        return (decoded, packets, encodedDuration)
    }

    func testEveryInputRateKeepsPitchAndDuration() throws {
        for rate in [16000.0, 24000.0, 44100.0, 48000.0, 96000.0] {
            for channels: AVAudioChannelCount in [1, 2] {
                let buffer = sineBuffer(sampleRate: rate, channels: channels, frequency: 1000, seconds: 2)
                let result = try encodeAndDecode(slices(of: buffer, sizes: [512, 470, 1024, 4096, 1]))
                let frequency = dominantFrequency(result.samples, sampleRate: 48000)
                XCTAssertEqual(frequency, 1000, accuracy: 5, "\(rate) Hz, \(channels) ch")
                XCTAssertEqual(result.encodedDuration, 2, accuracy: 0.03, "\(rate) Hz, \(channels) ch")
            }
        }
    }

    func testInterleavedInt16InputIsConverted() throws {
        let buffer = sineBuffer(sampleRate: 44100, channels: 1, frequency: 440, seconds: 2, interleaved: true, commonFormat: .pcmFormatInt16)
        let result = try encodeAndDecode([buffer])
        XCTAssertEqual(dominantFrequency(result.samples, sampleRate: 48000), 440, accuracy: 5)
        XCTAssertEqual(result.encodedDuration, 2, accuracy: 0.03)
    }

    func testPacketsDoNotDependOnHowTheInputIsSliced() throws {
        let buffer = sineBuffer(sampleRate: 48000, channels: 1, frequency: 700, seconds: 1)
        func packets(_ sizes: [Int]) throws -> [[Int16]] {
            let converter = try XCTUnwrap(VoiceRecorderInputConverter(inputFormat: buffer.format))
            let packetizer = VoiceRecorderPacketizer()
            var result: [[Int16]] = []
            for slice in slices(of: buffer, sizes: sizes) {
                converter.convert(slice) { pointer, count in
                    packetizer.append(pointer, count: count) { packet, packetCount in
                        result.append(Array(UnsafeBufferPointer(start: packet, count: packetCount)))
                    }
                }
            }
            return result
        }
        let reference = try packets([48000])
        XCTAssertEqual(reference.count, 50)
        XCTAssertEqual(try packets([1, 4096, 333, 960]), reference)
        XCTAssertEqual(try packets([128]), reference)
    }

    func testPacketizerKeepsTheRemainderForTheNextSamples() {
        let packetizer = VoiceRecorderPacketizer()
        var packets: [[Int16]] = []
        let first = (0 ..< 1000).map { Int16($0) }
        first.withUnsafeBufferPointer { packetizer.append($0.baseAddress!, count: $0.count) { packets.append(Array(UnsafeBufferPointer(start: $0, count: $1))) } }
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packetizer.pendingSamples, 40)
        let second = (1000 ..< 1920).map { Int16($0) }
        second.withUnsafeBufferPointer { packetizer.append($0.baseAddress!, count: $0.count) { packets.append(Array(UnsafeBufferPointer(start: $0, count: $1))) } }
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[1], (960 ..< 1920).map { Int16($0) })
        XCTAssertEqual(packetizer.pendingSamples, 0)
    }

    func testRecordingNeverChangesTheInputDeviceSampleRate() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("microphone access is not granted to the test runner")
        }
        guard let device = VoiceRecorderAudioEngine.defaultInputDevice(), let before = VoiceRecorderAudioEngine.nominalSampleRate(of: device) else {
            throw XCTSkip("no input device")
        }
        let engine = VoiceRecorderAudioEngine(inputDeviceUID: nil, voiceProcessing: false)
        let received = expectation(description: "buffers")
        received.assertForOverFulfill = false
        try engine.start { buffer in
            if buffer.frameLength > 0 {
                received.fulfill()
            }
        }
        wait(for: [received], timeout: 5)
        engine.stop()
        XCTAssertEqual(VoiceRecorderAudioEngine.nominalSampleRate(of: device), before)
    }
}
