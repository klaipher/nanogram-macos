import Foundation
import Postbox

@available(macOS 10.15, *)
public final class RecognitionFileCache {
    struct Entry: Codable {
        let texts: [TextRecognizing.Result.Detected]
        let barcodes: [TextRecognizing.Result.Barcode]
    }

    private static let lock = NSLock()
    private static var shared: [String: RecognitionFileCache] = [:]

    private let directory: URL
    private let maxEntries: Int
    private let queue = DispatchQueue(label: "org.telegram.text-recognition-cache", qos: .utility)

    public init(directory: URL, maxEntries: Int = 500) {
        self.directory = directory
        self.maxEntries = max(1, maxEntries)
    }

    public static func forPostbox(_ postbox: Postbox) -> RecognitionFileCache {
        let path = URL(fileURLWithPath: postbox.mediaBox.basePath).deletingLastPathComponent().appendingPathComponent("text-recognition", isDirectory: true)
        lock.lock()
        defer { lock.unlock() }
        if let cache = shared[path.path] {
            return cache
        }
        let cache = RecognitionFileCache(directory: path)
        shared[path.path] = cache
        return cache
    }

    func url(for stableId: MediaId) -> URL {
        return self.directory.appendingPathComponent("\(stableId.namespace)_\(stableId.id).json")
    }

    func get(_ stableId: MediaId) -> Entry? {
        return self.queue.sync {
            guard let data = try? Data(contentsOf: self.url(for: stableId)) else {
                return nil
            }
            return try? JSONDecoder().decode(Entry.self, from: data)
        }
    }

    func set(texts: [TextRecognizing.Result.Detected], barcodes: [TextRecognizing.Result.Barcode], stableId: MediaId) {
        self.queue.sync {
            guard let data = try? JSONEncoder().encode(Entry(texts: texts, barcodes: barcodes)) else {
                return
            }
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: nil)
            try? data.write(to: self.url(for: stableId), options: .atomic)
            self.prune()
        }
    }

    private func prune() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]), urls.count > self.maxEntries else {
            return
        }
        let sorted = urls.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        for url in sorted.dropFirst(self.maxEntries) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
