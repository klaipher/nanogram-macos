import Foundation
import AVFoundation
import Speech
import OpusBinding
import SwiftSignalKit
import NanogramDebug

public protocol LocalSpeechRecognizer: AnyObject, Sendable {
    func transcribe(_ buffer: AVAudioPCMBuffer, localeIdentifier: String) async -> String?
}


public final class LocalAudioTranscription: @unchecked Sendable {
    public static let debugOption = NanogramDebugOption.toggle(id: "voice.onDeviceTranscription", section: "Voice", title: "Transcribe voice messages on this Mac", detail: "Non-Premium accounts transcribe voice messages with Apple's on-device speech recognition; results stay on this Mac and are labelled on-device. Off: Telegram's server (Premium or trial).", defaultValue: true)

    public static let shared = LocalAudioTranscription(recognizer: LocalAudioTranscription.systemRecognizer())

    private let recognizer: LocalSpeechRecognizer?

    public init(recognizer: LocalSpeechRecognizer?) {
        self.recognizer = recognizer
    }

    public static var isEnabled: Bool {
        return LocalAudioTranscription.isEnabled(in: NanogramDebugSettings.shared)
    }

    public static func isEnabled(in settings: NanogramDebugSettings) -> Bool {
        if settings.isOverridden(LocalAudioTranscription.debugOption.id) {
            return settings.bool(LocalAudioTranscription.debugOption.id)
        }
        if case let .toggle(defaultValue) = LocalAudioTranscription.debugOption.kind {
            return defaultValue
        }
        return true
    }

    public static func isOnDevice(transcriptionId: Int64, isPending: Bool) -> Bool {
        return transcriptionId == 0 && !isPending
    }

    private static func systemRecognizer() -> LocalSpeechRecognizer? {
        if #available(macOS 26.0, *) {
            return ChainedSpeechRecognizer([SpeechAnalyzerRecognizer(), OnDeviceSpeechRecognizer()])
        } else if #available(macOS 10.15, *) {
            return OnDeviceSpeechRecognizer()
        } else {
            return nil
        }
    }

    public static func shouldTranscribeLocally(isEnabled: Bool, isPremium: Bool, isVoice: Bool, hasServerTranscription: Bool) -> Bool {
        return isEnabled && !isPremium && isVoice && !hasServerTranscription
    }

    public static func localeCandidates(appLanguage: String?, preferred: [String] = Locale.preferredLanguages + [Locale.current.identifier]) -> [String] {
        var result: [String] = []
        for identifier in [appLanguage].compactMap({ $0 }) + preferred {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            if !normalized.isEmpty, !result.contains(normalized) {
                result.append(normalized)
            }
        }
        return result
    }

    public static func decodeVoiceNote(path: String) -> AVAudioPCMBuffer? {
        guard let reader = OggOpusReader(path: path) else {
            return nil
        }
        var samples: [Int16] = []
        let chunkSamples = 960 * 8
        var chunk = [Int16](repeating: 0, count: chunkSamples)
        while true {
            let read = chunk.withUnsafeMutableBytes { reader.read($0.baseAddress!, bufSize: Int32(chunkSamples)) }
            if read <= 0 || read > chunkSamples {
                break
            }
            samples.append(contentsOf: chunk[0 ..< Int(read)])
        }
        guard !samples.isEmpty, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)), let data = buffer.floatChannelData?[0] else {
            return nil
        }
        for (index, sample) in samples.enumerated() {
            data[index] = Float(sample) / 32768.0
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    public func transcribe(path: String, localeIdentifiers: [String]) -> Signal<String?, NoError> {
        guard let recognizer = self.recognizer else {
            return .single(nil)
        }
        return Signal { subscriber in
            let output = TranscriptionOutput(subscriber)
            let task = Task.detached(priority: .userInitiated) {
                var result: String?
                if let buffer = LocalAudioTranscription.decodeVoiceNote(path: path) {
                    for identifier in localeIdentifiers {
                        if Task.isCancelled {
                            break
                        }
                        if let text = await recognizer.transcribe(buffer, localeIdentifier: identifier), !text.isEmpty {
                            result = text
                            break
                        }
                    }
                }
                if !Task.isCancelled {
                    output.finish(result)
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }
}

private final class TranscriptionOutput: @unchecked Sendable {
    private let subscriber: Subscriber<String?, NoError>

    init(_ subscriber: Subscriber<String?, NoError>) {
        self.subscriber = subscriber
    }

    func finish(_ result: String?) {
        self.subscriber.putNext(result)
        self.subscriber.putCompletion()
    }
}

public final class ChainedSpeechRecognizer: LocalSpeechRecognizer {
    private let recognizers: [LocalSpeechRecognizer]

    public init(_ recognizers: [LocalSpeechRecognizer]) {
        self.recognizers = recognizers
    }

    public func transcribe(_ buffer: AVAudioPCMBuffer, localeIdentifier: String) async -> String? {
        for recognizer in self.recognizers {
            if let text = await recognizer.transcribe(buffer, localeIdentifier: localeIdentifier) {
                return text
            }
        }
        return nil
    }
}

@available(macOS 10.15, *)
public final class OnDeviceSpeechRecognizer: LocalSpeechRecognizer {
    public init() {
    }

    private static func authorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    public func transcribe(_ buffer: AVAudioPCMBuffer, localeIdentifier: String) async -> String? {
        guard await OnDeviceSpeechRecognizer.authorized() else {
            return nil
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            return nil
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        request.append(buffer)
        request.endAudio()
        return await withCheckedContinuation { continuation in
            var resumed = false
            let lock = NSLock()
            func finish(_ value: String?) {
                lock.lock()
                defer { lock.unlock() }
                if !resumed {
                    resumed = true
                    continuation.resume(returning: value)
                }
            }
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result = result, result.isFinal {
                    finish(result.bestTranscription.formattedString)
                } else if error != nil {
                    finish(nil)
                }
            }
        }
    }
}

@available(macOS 26.0, *)
public final class SpeechAnalyzerRecognizer: LocalSpeechRecognizer {
    private static let installLock = NSLock()
    nonisolated(unsafe) private static var installing: Set<String> = []

    private let installsMissingAssets: Bool

    public init(installsMissingAssets: Bool = true) {
        self.installsMissingAssets = installsMissingAssets
    }

    private static func beginInstall(_ identifier: String) -> Bool {
        installLock.lock()
        defer { installLock.unlock() }
        return installing.insert(identifier).inserted
    }

    private static func endInstall(_ identifier: String) {
        installLock.lock()
        installing.remove(identifier)
        installLock.unlock()
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var provided = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error, withInputFrom: { _, status in
            if provided {
                status.pointee = .endOfStream
                return nil
            }
            provided = true
            status.pointee = .haveData
            return buffer
        })
        return error == nil ? output : nil
    }

    public func transcribe(_ buffer: AVAudioPCMBuffer, localeIdentifier: String) async -> String? {
        guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            return nil
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status == .installed else {
            if status == .supported, self.installsMissingAssets, SpeechAnalyzerRecognizer.beginInstall(locale.identifier) {
                Task.detached(priority: .utility) {
                    try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
                    SpeechAnalyzerRecognizer.endInstall(locale.identifier)
                }
            }
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: buffer.format), let input = SpeechAnalyzerRecognizer.convert(buffer, to: format) else {
            return nil
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task { () -> String in
            var text = ""
            do {
                for try await result in transcriber.results where result.isFinal {
                    text += String(result.text.characters)
                }
            } catch {
            }
            return text
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: input))
        continuation.finish()
        do {
            try await analyzer.prepareToAnalyze(in: format)
            _ = try await analyzer.analyzeSequence(stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            return nil
        }
        let text = await results.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
