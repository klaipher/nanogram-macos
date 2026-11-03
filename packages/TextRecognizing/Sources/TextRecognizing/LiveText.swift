import Foundation
import CoreGraphics
import Vision
import SwiftSignalKit
#if canImport(VisionKit)
import VisionKit
#endif

public struct LiveTextCode: Equatable {
    public let payload: String
    public let bounds: CGRect

    public init(payload: String, bounds: CGRect) {
        self.payload = payload
        self.bounds = bounds
    }

    public var link: String? {
        let trimmed = self.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https", "tg", "ton", "mailto"].contains(scheme) {
            return trimmed
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = detector.matches(in: trimmed, options: [], range: range)
        if matches.count == 1, let match = matches.first, match.range == range, let url = match.url {
            return url.absoluteString
        }
        return nil
    }

    public var isTelegramLink: Bool {
        guard let link = self.link, let url = URL(string: link), let scheme = url.scheme?.lowercased() else {
            return false
        }
        if scheme == "tg" {
            return true
        }
        guard scheme == "http" || scheme == "https", let host = url.host?.lowercased() else {
            return false
        }
        return ["t.me", "telegram.me", "telegram.dog"].contains(host)
    }
}

public enum LiveTextCodes {
    public static func detect(in image: CGImage) -> [LiveTextCode] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return []
        }
        var result: [LiveTextCode] = []
        for observation in request.results ?? [] {
            if let payload = observation.payloadStringValue, !payload.isEmpty {
                result.append(LiveTextCode(payload: payload, bounds: observation.boundingBox))
            }
        }
        return result
    }

    public static func code(at normalizedPoint: CGPoint, in codes: [LiveTextCode]) -> LiveTextCode? {
        return codes.first(where: { $0.bounds.contains(normalizedPoint) })
    }
}

public enum LiveTextSchedule {
    public struct State<Image> {
        public let image: Image?
        public let isEligible: Bool

        public init(image: Image?, isEligible: Bool) {
            self.image = image
            self.isEligible = isEligible
        }
    }

    public static func analysis<Image, Result>(states: Signal<State<Image>, NoError>, dwell: Double, queue: Queue, analyze: @escaping (Image) -> Signal<Result?, NoError>) -> Signal<Result?, NoError> {
        return states
        |> mapToSignal { state -> Signal<Result?, NoError> in
            guard state.isEligible, let image = state.image else {
                return .single(nil)
            }
            return (Signal<Result?, NoError>.complete() |> delay(dwell, queue: queue)) |> then(deferred { analyze(image) })
        }
    }
}

public enum LiveTextLegacyStore {
    public static let preferencesKey: Int32 = 1003

    public static func removeFiles(mediaBoxBasePath: String) -> Bool {
        let directory = URL(fileURLWithPath: mediaBoxBasePath).deletingLastPathComponent().appendingPathComponent("text-recognition", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return false
        }
        return (try? FileManager.default.removeItem(at: directory)) != nil
    }
}

#if canImport(VisionKit)
@available(macOS 13.0, *)
public final class LiveTextResult {
    public let analysis: ImageAnalysis
    public let codes: [LiveTextCode]

    init(analysis: ImageAnalysis, codes: [LiveTextCode]) {
        self.analysis = analysis
        self.codes = codes
    }

    public var transcript: String {
        return self.analysis.transcript
    }

    public var hasContent: Bool {
        return !self.codes.isEmpty || self.analysis.hasResults(for: [.text, .machineReadableCode])
    }
}

@available(macOS 13.0, *)
public final class LiveTextAnalyzer {
    public static let shared = LiveTextAnalyzer()

    private let analyzer = ImageAnalyzer()

    public static var isSupported: Bool {
        return ImageAnalyzer.isSupported
    }

    public func analyze(_ image: CGImage) -> Signal<LiveTextResult?, NoError> {
        let analyzer = self.analyzer
        return Signal { subscriber in
            let task = Task.detached(priority: .utility) {
                var result: LiveTextResult?
                if ImageAnalyzer.isSupported, let analysis = try? await analyzer.analyze(image, orientation: .up, configuration: ImageAnalyzer.Configuration([.text, .machineReadableCode])) {
                    result = LiveTextResult(analysis: analysis, codes: LiveTextCodes.detect(in: image))
                }
                if !Task.isCancelled {
                    subscriber.putNext(result)
                    subscriber.putCompletion()
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }
}
#endif
