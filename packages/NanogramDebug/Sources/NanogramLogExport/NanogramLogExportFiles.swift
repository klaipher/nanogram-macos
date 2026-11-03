import Foundation
import Zip

public enum NanogramLogExportFiles {
    public static let keepDuration: TimeInterval = 7 * 24 * 60 * 60

    public static func defaultRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Nanogram", isDirectory: true).appendingPathComponent("nanogram-log-export", isDirectory: true)
    }

    public static func makeDirectory(root: URL) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func prune(root: URL, now: Date = Date()) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        for entry in entries {
            guard let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                continue
            }
            if now.timeIntervalSince(date) > NanogramLogExportFiles.keepDuration {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    public static func prepare(spec: NanogramLogExportSpec, sources: [URL], in directory: URL) throws -> [URL] {
        let present = sources.filter { !regularFiles(in: $0).isEmpty }
        if present.isEmpty {
            return []
        }
        switch spec.packaging {
        case .archive:
            let archive = directory.appendingPathComponent(spec.archiveName)
            try Zip.zipFiles(paths: present, zipFilePath: archive, password: nil, progress: nil)
            return [archive]
        case .separateFiles:
            var result: [URL] = []
            for file in present.flatMap({ regularFiles(in: $0) }) {
                let target = directory.appendingPathComponent("\(spec.fileBaseName)-\(file.lastPathComponent)")
                if FileManager.default.fileExists(atPath: target.path) {
                    continue
                }
                try FileManager.default.copyItem(at: file, to: target)
                result.append(target)
            }
            return result
        }
    }

    static func regularFiles(in url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return [url]
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [URL] = []
        while let next = enumerator.nextObject() as? URL {
            if (try? next.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(next)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
