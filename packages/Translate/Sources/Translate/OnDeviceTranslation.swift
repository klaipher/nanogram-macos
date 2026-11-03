import Foundation
import SwiftSignalKit
#if canImport(Translation)
import Translation
#endif

public enum OnDeviceTranslationStatus {
    case installed
    case supported
    case unsupported
}

public protocol OnDeviceTranslationProvider: AnyObject {
    func status(from: String, to: String) async -> OnDeviceTranslationStatus
    func translate(_ texts: [String], from: String, to: String) async throws -> [String]
}

public final class OnDeviceTranslation {
    public static let shared = OnDeviceTranslation(provider: OnDeviceTranslation.systemProvider())

    private let provider: OnDeviceTranslationProvider?

    public init(provider: OnDeviceTranslationProvider?) {
        self.provider = provider
    }

    public var isAvailable: Bool {
        return self.provider != nil
    }

    private static func systemProvider() -> OnDeviceTranslationProvider? {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            return SystemTranslationProvider()
        }
        #endif
        return nil
    }

    public static func systemLanguageCode(_ code: String) -> String {
        let parts = code.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased() else {
            return code
        }
        guard parts.count > 1 else {
            return language
        }
        let rest = parts.dropFirst().map { part -> String in
            if part.count == 4 {
                return part.prefix(1).uppercased() + part.dropFirst().lowercased()
            } else {
                return part.uppercased()
            }
        }
        return ([language] + rest).joined(separator: "-")
    }

    private static func baseLanguage(_ code: String) -> String {
        return code.split(separator: "-").first.map(String.init)?.lowercased() ?? code.lowercased()
    }

    public func translate(texts: [AnyHashable: String], from: String, to: String) -> Signal<[AnyHashable: String]?, NoError> {
        guard let provider = self.provider, !texts.isEmpty else {
            return .single(nil)
        }
        let source = OnDeviceTranslation.systemLanguageCode(from)
        let target = OnDeviceTranslation.systemLanguageCode(to)
        if OnDeviceTranslation.baseLanguage(source) == OnDeviceTranslation.baseLanguage(target) {
            return .single(nil)
        }
        let keys = Array(texts.keys)
        let values = keys.map { texts[$0]! }
        return Signal { subscriber in
            let task = Task {
                var result: [AnyHashable: String]?
                if await provider.status(from: source, to: target) == .installed {
                    if let translated = try? await provider.translate(values, from: source, to: target), translated.count == keys.count {
                        var mapped: [AnyHashable: String] = [:]
                        for (key, value) in zip(keys, translated) {
                            mapped[key] = value
                        }
                        result = mapped
                    }
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

    public func translate(text: String, from: String?, to: String) -> Signal<(detect: String?, result: String)?, NoError> {
        guard let from = from ?? Translate.detectLanguage(for: text) else {
            return .single(nil)
        }
        let detected = OnDeviceTranslation.baseLanguage(from)
        return self.translate(texts: [AnyHashable(0): text], from: from, to: to)
        |> map { result -> (detect: String?, result: String)? in
            guard let value = result?[AnyHashable(0)] else {
                return nil
            }
            return (detect: detected, result: value)
        }
    }
}

#if canImport(Translation)
@available(macOS 26.0, *)
public final class SystemTranslationProvider: OnDeviceTranslationProvider {
    public init() {
    }

    public func status(from: String, to: String) async -> OnDeviceTranslationStatus {
        switch await LanguageAvailability().status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to)) {
        case .installed:
            return .installed
        case .supported:
            return .supported
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }

    public func translate(_ texts: [String], from: String, to: String) async throws -> [String] {
        let session = TranslationSession(installedSource: Locale.Language(identifier: from), target: Locale.Language(identifier: to))
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)") }
        let responses = try await session.translations(from: requests)
        var result = texts
        for response in responses {
            if let identifier = response.clientIdentifier, let index = Int(identifier), index < result.count {
                result[index] = response.targetText
            }
        }
        return result
    }
}
#endif
