import Foundation
#if canImport(Translation) && canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI
import Translation

@available(macOS 15.0, *)
@MainActor
final class HiddenTranslationModel: ObservableObject {
    struct Job {
        let id: Int
        let texts: [String]
        let from: String
        let to: String
        let completion: ([String]?) -> Void
    }

    @Published var configuration: TranslationSession.Configuration?
    private var jobs: [Job] = []
    private var nextId = 0

    func enqueue(texts: [String], from: String, to: String, completion: @escaping ([String]?) -> Void) -> Int {
        let id = self.nextId
        self.nextId += 1
        self.jobs.append(Job(id: id, texts: texts, from: from, to: to, completion: completion))
        if self.jobs.count == 1 {
            self.kick()
        }
        return id
    }

    func cancel(_ id: Int) {
        if let index = self.jobs.firstIndex(where: { $0.id == id }) {
            let job = self.jobs.remove(at: index)
            job.completion(nil)
        }
    }

    private func matches(_ job: Job) -> Bool {
        guard let configuration = self.configuration else {
            return false
        }
        return configuration.source == Locale.Language(identifier: job.from) && configuration.target == Locale.Language(identifier: job.to)
    }

    private func kick() {
        guard let job = self.jobs.first else {
            return
        }
        if self.matches(job) {
            self.configuration?.invalidate()
        } else {
            self.configuration = TranslationSession.Configuration(source: Locale.Language(identifier: job.from), target: Locale.Language(identifier: job.to))
        }
    }

    func run(_ session: TranslationSession) async {
        guard let job = self.jobs.first else {
            return
        }
        guard self.matches(job) else {
            self.kick()
            return
        }
        let requests = job.texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)") }
        var result: [String]?
        do {
            let responses = try await session.translations(from: requests)
            var translated = job.texts
            for response in responses {
                if let identifier = response.clientIdentifier, let index = Int(identifier), index < translated.count {
                    translated[index] = response.targetText
                }
            }
            result = translated
        } catch {
            result = nil
        }
        if let index = self.jobs.firstIndex(where: { $0.id == job.id }) {
            self.jobs.remove(at: index)
            job.completion(result)
        }
        self.kick()
    }
}

@available(macOS 15.0, *)
private struct HiddenTranslationView: View {
    @ObservedObject var model: HiddenTranslationModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(self.model.configuration, action: { session in
                await self.model.run(session)
            })
    }
}

@available(macOS 15.0, *)
public final class HiddenViewTranslationProvider: OnDeviceTranslationProvider {
    public enum Failure: Error {
        case noWindow
        case failed
    }

    private let timeout: TimeInterval
    private let hostWindow: @MainActor () -> NSWindow?
    @MainActor private var model: HiddenTranslationModel?
    @MainActor private var hostView: NSView?

    public init(timeout: TimeInterval = 15.0, hostWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) }) {
        self.timeout = timeout
        self.hostWindow = hostWindow
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

    @MainActor
    private func attachedModel() -> HiddenTranslationModel? {
        guard let window = self.hostWindow(), let contentView = window.contentView else {
            return nil
        }
        let model = self.model ?? HiddenTranslationModel()
        self.model = model
        if let hostView = self.hostView, hostView.window === window {
            return model
        }
        self.hostView?.removeFromSuperview()
        let hostView = NSHostingView(rootView: HiddenTranslationView(model: model))
        hostView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        hostView.alphaValue = 0.01
        contentView.addSubview(hostView)
        self.hostView = hostView
        return model
    }

    public func translate(_ texts: [String], from: String, to: String) async throws -> [String] {
        let timeout = self.timeout
        let result: [String]? = await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard let model = self.attachedModel() else {
                    continuation.resume(returning: nil)
                    return
                }
                var finished = false
                let id = model.enqueue(texts: texts, from: from, to: to, completion: { value in
                    if !finished {
                        finished = true
                        continuation.resume(returning: value)
                    }
                })
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    model.cancel(id)
                }
            }
        }
        guard let result = result else {
            throw Failure.failed
        }
        return result
    }
}
#endif
