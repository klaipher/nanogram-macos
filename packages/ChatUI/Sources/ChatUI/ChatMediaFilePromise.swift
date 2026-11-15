import Cocoa
import UniformTypeIdentifiers
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramContext
import TelegramMediaUtils

enum ChatMediaPromiseNaming {
    static func fileType(mimeType: String?) -> String {
        if #available(macOS 11.0, *), let mimeType = mimeType, let type = UTType(mimeType: mimeType) {
            return type.identifier
        }
        return "public.data"
    }

    static func preferredExtension(mimeType: String?) -> String? {
        if #available(macOS 11.0, *), let mimeType = mimeType {
            return UTType(mimeType: mimeType)?.preferredFilenameExtension
        }
        return nil
    }

    static func fileName(preferred: String?, mimeType: String?, fallbackStem: String) -> String {
        let cleaned = sanitized(preferred ?? "")
        let stem = cleaned.isEmpty ? fallbackStem : cleaned
        // The fallback stem contains dots (e.g. "01.00.00"), so "00" would look like an extension; only a
        // caller-supplied name can already carry one.
        if !cleaned.isEmpty, !(stem as NSString).pathExtension.isEmpty {
            return stem
        }
        let ext = preferredExtension(mimeType: mimeType)
        guard let ext = ext, !ext.isEmpty else {
            return stem
        }
        return stem + "." + ext
    }

    static func fallbackStem(isImage: Bool, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return (isImage ? "IMAGE " : "FILE ") + formatter.string(from: date)
    }

    static func sanitized(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\0").union(.controlCharacters)
        let parts = name.components(separatedBy: forbidden)
        let joined = parts.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.hasPrefix(".") ? "_" + joined.dropFirst() : joined
    }
}

enum ChatMediaPromiseError: Error {
    case unavailable
}

final class ChatMediaFilePromise: NSObject, NSFilePromiseProviderDelegate {
    static let defaultTimeout: Double = 30 * 60

    private let fileName: String
    private let data: Signal<MediaResourceData, NoError>
    private let fetch: Signal<Void, NoError>?
    private let timeoutInterval: Double
    private let queue: OperationQueue
    private let disposable = MetaDisposable()
    private let lock = NSLock()
    private var activeCompletion: PromiseCompletion?
    private var retainedWhileWriting: ChatMediaFilePromise?

    init(fileName: String, data: Signal<MediaResourceData, NoError>, fetch: Signal<Void, NoError>?, timeout: Double = ChatMediaFilePromise.defaultTimeout) {
        self.fileName = fileName
        self.data = data
        self.fetch = fetch
        self.timeoutInterval = timeout
        self.queue = OperationQueue()
        self.queue.name = "nanogram.chatMediaFilePromise"
        self.queue.qualityOfService = .userInitiated
        super.init()
    }

    convenience init(fileName: String, mediaBox: MediaBox, resource: MediaResource, fetch: Signal<Void, NoError>?) {
        let data = mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: true))
        self.init(fileName: fileName, data: data, fetch: fetch)
    }

    deinit {
        disposable.dispose()
    }

    func cancel() {
        finish(CocoaError(.userCancelled))
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let completion = activeCompletion
        activeCompletion = nil
        let retained = retainedWhileWriting
        retainedWhileWriting = nil
        lock.unlock()
        disposable.set(nil)
        completion?.complete(error)
        withExtendedLifetime(retained) {}
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        return fileName
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        return queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let completion = PromiseCompletion(completionHandler)
        lock.lock()
        activeCompletion = completion
        retainedWhileWriting = self
        lock.unlock()

        let source = data
        |> filter { $0.complete }
        |> take(1)
        |> timeout(timeoutInterval, queue: Queue.concurrentDefaultQueue(), alternate: .complete())

        let disposables = DisposableSet()
        if let fetch = fetch {
            disposables.add(fetch.start())
        }
        let received = Atomic<Bool>(value: false)
        disposables.add(source.start(next: { [weak self] data in
            guard let self = self else {
                return
            }
            _ = received.swap(true)
            let path = data.path
            self.queue.addOperation {
                do {
                    let manager = FileManager.default
                    if manager.fileExists(atPath: url.path) {
                        try manager.removeItem(at: url)
                    }
                    try manager.copyItem(atPath: path, toPath: url.path)
                    self.finish(nil)
                } catch {
                    self.finish(error)
                }
            }
        }, completed: { [weak self] in
            if !received.with({ $0 }) {
                self?.finish(ChatMediaPromiseError.unavailable)
            }
        }))
        disposable.set(disposables)
    }
}

final class PromiseCompletion {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func complete(_ error: Error?) {
        lock.lock()
        let current = handler
        handler = nil
        lock.unlock()
        current?(error)
    }
}
