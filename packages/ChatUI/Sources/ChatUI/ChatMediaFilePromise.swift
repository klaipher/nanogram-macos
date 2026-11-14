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
        if !(stem as NSString).pathExtension.isEmpty {
            return stem
        }
        let ext = preferredExtension(mimeType: mimeType)
        guard let ext = ext, !ext.isEmpty else {
            return stem
        }
        return stem + "." + ext
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
    private let fileName: String
    private let mediaBox: MediaBox
    private let resource: MediaResource
    private let fetch: Signal<Void, NoError>?
    private let queue: OperationQueue
    private let disposable = MetaDisposable()

    init(fileName: String, mediaBox: MediaBox, resource: MediaResource, fetch: Signal<Void, NoError>?) {
        self.fileName = fileName
        self.mediaBox = mediaBox
        self.resource = resource
        self.fetch = fetch
        self.queue = OperationQueue()
        self.queue.name = "nanogram.chatMediaFilePromise"
        self.queue.qualityOfService = .userInitiated
        super.init()
    }

    deinit {
        disposable.dispose()
    }

    func cancel() {
        disposable.set(nil)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        return fileName
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        return queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let once = PromiseCompletion(completionHandler)

        let data = mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: true))
        |> filter { $0.complete }
        |> take(1)

        let disposables = DisposableSet()
        if let fetch = fetch {
            disposables.add(fetch.start())
        }
        disposables.add(data.start(next: { data in
            do {
                let manager = FileManager.default
                if manager.fileExists(atPath: url.path) {
                    try manager.removeItem(at: url)
                }
                try manager.copyItem(atPath: data.path, toPath: url.path)
                once.complete(nil)
            } catch {
                once.complete(error)
            }
        }, completed: {
            once.complete(ChatMediaPromiseError.unavailable)
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
