import XCTest
import AVFoundation
import Speech
import AppKit
import OpusBinding
import SwiftSignalKit
import VoiceRecorderInput
@testable import LocalAudioTranscription

private final class FakeRecognizer: LocalSpeechRecognizer {
    var available: Set<String>
    var requests: [(locale: String, frames: AVAudioFrameCount, rate: Double)] = []

    init(available: Set<String>) {
        self.available = available
    }

    func transcribe(_ buffer: AVAudioPCMBuffer, localeIdentifier: String) async -> String? {
        self.requests.append((localeIdentifier, buffer.frameLength, buffer.format.sampleRate))
        return self.available.contains(localeIdentifier) ? "text in \(localeIdentifier)" : nil
    }
}

final class LocalAudioTranscriptionTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        for path in self.paths {
            try? FileManager.default.removeItem(atPath: path)
        }
        super.tearDown()
    }

    private func writeOgg(_ buffers: [AVAudioPCMBuffer]) throws -> String {
        let converter = try XCTUnwrap(VoiceRecorderInputConverter(inputFormat: buffers[0].format))
        let packetizer = VoiceRecorderPacketizer()
        let item = TGDataItem(data: Data())!
        let writer = TGOggOpusWriter()
        XCTAssertTrue(writer.begin(with: item))
        let write: (UnsafePointer<Int16>, Int) -> Void = { pointer, count in
            _ = writer.writeFrame(UnsafeMutableRawPointer(mutating: pointer).assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(count * 2))
        }
        for buffer in buffers {
            converter.convert(buffer) { packetizer.append($0, count: $1, packet: write) }
        }
        converter.flush { packetizer.append($0, count: $1, packet: write) }
        XCTAssertTrue(writer.writeFrame(nil, frameByteCount: 0))
        let path = NSTemporaryDirectory() + "local-transcription-\(UUID().uuidString).ogg"
        try item.data().write(to: URL(fileURLWithPath: path))
        self.paths.append(path)
        return path
    }

    private func tone(seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44100 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0 ..< Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = Float(0.3 * sin(2 * Double.pi * 440 * Double(i) / 44100))
        }
        return buffer
    }

    private func await<T>(_ signal: Signal<T, NoError>) -> T? {
        let done = expectation(description: "signal")
        var value: T?
        let disposable = signal.start(next: { value = $0 }, completed: { done.fulfill() })
        wait(for: [done], timeout: 120)
        disposable.dispose()
        return value
    }

    func testVoiceNoteDecodesToFortyEightKilohertzMono() throws {
        let path = try self.writeOgg([self.tone(seconds: 1.5)])
        let buffer = try XCTUnwrap(LocalAudioTranscription.decodeVoiceNote(path: path))
        XCTAssertEqual(buffer.format.sampleRate, 48000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(Double(buffer.frameLength) / 48000, 1.5, accuracy: 0.05)
    }

    func testBrokenFileGivesNil() throws {
        let path = NSTemporaryDirectory() + "broken-\(UUID().uuidString).ogg"
        try Data("not ogg".utf8).write(to: URL(fileURLWithPath: path))
        self.paths.append(path)
        XCTAssertNil(LocalAudioTranscription.decodeVoiceNote(path: path))
        let transcription = LocalAudioTranscription(recognizer: FakeRecognizer(available: ["en-US"]))
        XCTAssertEqual(self.await(transcription.transcribe(path: path, localeIdentifiers: ["en-US"])) ?? nil, nil)
    }

    func testTheFirstAvailableLocaleWins() throws {
        let path = try self.writeOgg([self.tone(seconds: 1)])
        let recognizer = FakeRecognizer(available: ["de-DE", "en-US"])
        let transcription = LocalAudioTranscription(recognizer: recognizer)
        let text = self.await(transcription.transcribe(path: path, localeIdentifiers: ["uk-UA", "de-DE", "en-US"])) ?? nil
        XCTAssertEqual(text, "text in de-DE")
        XCTAssertEqual(recognizer.requests.map { $0.locale }, ["uk-UA", "de-DE"])
        XCTAssertEqual(recognizer.requests.first?.rate, 48000)
    }

    func testNoLocaleAvailableGivesNilSoTheServerIsUsed() throws {
        let path = try self.writeOgg([self.tone(seconds: 1)])
        let transcription = LocalAudioTranscription(recognizer: FakeRecognizer(available: []))
        XCTAssertEqual(self.await(transcription.transcribe(path: path, localeIdentifiers: ["en-US"])) ?? nil, nil)
        let none = LocalAudioTranscription(recognizer: nil)
        XCTAssertEqual(self.await(none.transcribe(path: path, localeIdentifiers: ["en-US"])) ?? nil, nil)
    }

    func testLocaleCandidatesPutTheAppLanguageFirstWithoutDuplicates() {
        XCTAssertEqual(LocalAudioTranscription.localeCandidates(appLanguage: "de", preferred: ["en-US", "de-DE", "en-GB"]), ["de", "en-US", "de-DE", "en-GB"])
        XCTAssertEqual(LocalAudioTranscription.localeCandidates(appLanguage: nil, preferred: ["en-US", "en-US"]), ["en-US"])
    }

    func testTheActionUsesTheLocalEngineOnlyWhenTheSwitchIsOn() {
        XCTAssertTrue(LocalAudioTranscription.shouldTranscribeLocally(isEnabled: true, isPremium: false, isVoice: true, hasServerTranscription: false))
        XCTAssertFalse(LocalAudioTranscription.shouldTranscribeLocally(isEnabled: false, isPremium: false, isVoice: true, hasServerTranscription: false))
        XCTAssertFalse(LocalAudioTranscription.shouldTranscribeLocally(isEnabled: true, isPremium: true, isVoice: true, hasServerTranscription: false))
        XCTAssertFalse(LocalAudioTranscription.shouldTranscribeLocally(isEnabled: true, isPremium: false, isVoice: false, hasServerTranscription: false))
        XCTAssertFalse(LocalAudioTranscription.shouldTranscribeLocally(isEnabled: true, isPremium: false, isVoice: true, hasServerTranscription: true))
    }

    private func spokenVoiceNote() throws -> (path: String, seconds: Double) {
        let aiff = NSTemporaryDirectory() + "spoken-\(UUID().uuidString).aiff"
        self.paths.append(aiff)
        let synthesizer = NSSpeechSynthesizer()
        XCTAssertTrue(synthesizer.startSpeaking("Hello world, this is a voice message test.", to: URL(fileURLWithPath: aiff)))
        let deadline = Date().addingTimeInterval(20)
        while synthesizer.isSpeaking && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: aiff))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return (try self.writeOgg([buffer]), Double(buffer.frameLength) / buffer.format.sampleRate)
    }

    func testSpokenVoiceNoteIsTranscribedBySpeechRecognizerOnDevice() throws {
        guard #available(macOS 10.15, *), SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw XCTSkip("speech recognition is not authorized for the test runner")
        }
        let note = try self.spokenVoiceNote()
        let transcription = LocalAudioTranscription(recognizer: OnDeviceSpeechRecognizer())
        guard let text = self.await(transcription.transcribe(path: note.path, localeIdentifiers: ["en-US"])) ?? nil else {
            throw XCTSkip("on-device en-US recognition is unavailable")
        }
        XCTAssertTrue(text.lowercased().contains("hello"), text)
    }

    func testSpokenVoiceNoteIsTranscribedOnDevice() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("needs macOS 26")
        }
        let aiff = NSTemporaryDirectory() + "spoken-\(UUID().uuidString).aiff"
        self.paths.append(aiff)
        let synthesizer = NSSpeechSynthesizer()
        XCTAssertTrue(synthesizer.startSpeaking("Hello world, this is a voice message test.", to: URL(fileURLWithPath: aiff)))
        let deadline = Date().addingTimeInterval(20)
        while synthesizer.isSpeaking && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: aiff))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let path = try self.writeOgg([buffer])
        let started = Date()
        let transcription = LocalAudioTranscription(recognizer: SpeechAnalyzerRecognizer(installsMissingAssets: false))
        guard let text = self.await(transcription.transcribe(path: path, localeIdentifiers: ["en-US"])) ?? nil else {
            throw XCTSkip("en-US speech assets are not installed")
        }
        XCTAssertTrue(text.lowercased().contains("hello"), text)
        XCTAssertTrue(text.lowercased().contains("voice"), text)
        print("on-device transcription of \(Double(buffer.frameLength) / buffer.format.sampleRate) s took \(Date().timeIntervalSince(started)) s: \(text)")
    }
}
