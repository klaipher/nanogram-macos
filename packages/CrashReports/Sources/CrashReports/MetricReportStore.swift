import CryptoKit
import Foundation

public final class MetricReportStore {
    public enum Kind: String {
        case metrics
        case diagnostics
    }

    public static let shared = MetricReportStore(directory: MetricReportStore.defaultDirectory())

    private let directory: URL
    private let maxFiles: Int
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "org.telegram.metric-reports")

    public init(directory: URL, maxFiles: Int = 60, maxBytes: Int = 8 * 1024 * 1024) {
        self.directory = directory
        self.maxFiles = max(1, maxFiles)
        self.maxBytes = max(1, maxBytes)
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Telegram", isDirectory: true).appendingPathComponent("MetricKit", isDirectory: true)
    }

    @discardableResult
    public func store(_ json: Data, kind: Kind, intervalEnd: Date) throws -> Bool {
        return try self.queue.sync {
            let hash = SHA256.hash(data: json).prefix(8).map { String(format: "%02x", $0) }.joined()
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: nil)
            var directory = self.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)

            let existing = try self.storedFiles()
            if existing.contains(where: { $0.url.lastPathComponent.hasSuffix("-\(hash).json") }) {
                return false
            }
            let name = "\(kind.rawValue)-\(Int64(intervalEnd.timeIntervalSince1970))-\(hash).json"
            try json.write(to: self.directory.appendingPathComponent(name), options: .atomic)
            try self.prune()
            return true
        }
    }

    public func reports() -> [(name: String, path: String)] {
        return self.queue.sync {
            return ((try? self.storedFiles()) ?? []).map { ($0.url.lastPathComponent, $0.url.path) }
        }
    }

    @discardableResult
    public func export(to target: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: nil)
        var exported: [URL] = []
        for report in self.reports() {
            let destination = target.appendingPathComponent(report.name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: report.path), to: destination)
            exported.append(destination)
        }
        return exported
    }

    private func storedFiles() throws -> [(url: URL, date: Int64, size: Int)] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        var result: [(url: URL, date: Int64, size: Int)] = []
        for url in urls where url.pathExtension == "json" {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count == 3, let date = Int64(parts[1]) else {
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            result.append((url, date, size))
        }
        return result.sorted {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
    }

    private func prune() throws {
        var totalBytes = 0
        for (index, file) in try self.storedFiles().enumerated() {
            totalBytes += file.size
            if index >= self.maxFiles || (index > 0 && totalBytes > self.maxBytes) {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }
}
