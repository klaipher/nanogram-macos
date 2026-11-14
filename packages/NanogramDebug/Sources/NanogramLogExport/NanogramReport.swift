import Foundation

public struct NanogramReportDevice: Equatable, Sendable {
    public var model: String
    public var chip: String
    public var systemVersion: String
    public var appVersion: String
    public var buildNumber: String

    public init(model: String, chip: String, systemVersion: String, appVersion: String, buildNumber: String) {
        self.model = model
        self.chip = chip
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.buildNumber = buildNumber
    }

    public static func current(bundle: Bundle = .main) -> NanogramReportDevice {
        let info = bundle.infoDictionary
        return NanogramReportDevice(
            model: sysctlString("hw.model") ?? "unknown",
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            buildNumber: info?["CFBundleVersion"] as? String ?? "?"
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public struct NanogramReportSection: Equatable, Sendable {
    public let folder: String
    public let title: String
    public let sources: [URL]

    public init(folder: String, title: String, sources: [URL]) {
        self.folder = folder
        self.title = title
        self.sources = sources
    }
}

public enum NanogramReport {
    public static let includedNote = "Includes app logs, call logs, crash info, energy and CPU numbers and diagnostic settings. No messages, contacts or phone numbers." //TODOLANG
    public static let readmeFileName = "README.txt"
    public static let settingsFileName = "settings.txt"
    public static let energyFileName = "energy.txt"

    public static let totalByteLimit = 40 * 1024 * 1024
    public static let sectionByteLimit = 16 * 1024 * 1024
    public static let fileByteLimit = 8 * 1024 * 1024

    /// Copies every section into `<root>/nanogram-report-<stamp>/<folder>/`, newest files first and under the size caps,
    /// then writes the settings and the README listing every file and every file left out. Returns the staged folder,
    /// ready to zip.
    public static func stage(device: NanogramReportDevice, sections: [NanogramReportSection], settings: [String], extraFiles: [(name: String, text: String)] = [], date: Date = Date(), totalBytes: Int = totalByteLimit, sectionBytes: Int = sectionByteLimit, fileBytes: Int = fileByteLimit, in root: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = root.appendingPathComponent("nanogram-report-\(stamp(date))-\(UUID().uuidString.prefix(6))", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var counts: [(title: String, files: [(path: String, size: Int)])] = []
            var omitted: [(path: String, size: Int, reason: String)] = []
            var total = 0
            for section in sections {
                var candidates: [(file: URL, name: String, size: Int, modified: Date)] = []
                var used = Set<String>()
                for source in section.sources {
                    var isDirectory: ObjCBool = false
                    let exists = fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)
                    let base = isDirectory.boolValue ? source.standardizedFileURL.path : source.deletingLastPathComponent().standardizedFileURL.path
                    for file in NanogramLogExportFiles.regularFiles(in: source) where exists {
                        var relative = String(file.standardizedFileURL.path.dropFirst(base.count))
                        if relative.hasPrefix("/") {
                            relative.removeFirst()
                        }
                        if isDirectory.boolValue {
                            relative = source.lastPathComponent + "/" + relative
                        }
                        var name = relative
                        var suffix = 1
                        while used.contains(name) {
                            suffix += 1
                            name = "\(suffix)-\(relative)"
                        }
                        used.insert(name)
                        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        candidates.append((file, name, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
                    }
                }
                candidates.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.name < $1.name }
                var files: [(path: String, size: Int)] = []
                var sectionTotal = 0
                for candidate in candidates {
                    let path = section.folder + "/" + candidate.name
                    if candidate.size > fileBytes {
                        omitted.append((path, candidate.size, "over the per-file limit"))
                        continue
                    }
                    if total + candidate.size > totalBytes || sectionTotal + candidate.size > sectionBytes {
                        omitted.append((path, candidate.size, "over the report size limit"))
                        continue
                    }
                    let target = directory.appendingPathComponent(section.folder, isDirectory: true).appendingPathComponent(candidate.name)
                    do {
                        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fileManager.copyItem(at: candidate.file, to: target)
                    } catch {
                        omitted.append((path, candidate.size, "could not be read"))
                        continue
                    }
                    total += candidate.size
                    sectionTotal += candidate.size
                    files.append((path, candidate.size))
                }
                counts.append((section.title, files))
            }
            let settingsText = settingsFileText(settings)
            try Data(settingsText.utf8).write(to: directory.appendingPathComponent(settingsFileName))
            for extra in extraFiles {
                try Data(extra.text.utf8).write(to: directory.appendingPathComponent(extra.name))
            }
            let readme = readme(device: device, sections: counts, omitted: omitted, extraFiles: extraFiles.map { $0.name }, date: date)
            try Data(readme.utf8).write(to: directory.appendingPathComponent(readmeFileName))
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return directory
    }

    public static func settingsLines(_ values: [(id: String, value: String)]) -> [String] {
        return values.sorted { $0.id < $1.id }.map { "\($0.id) = \($0.value)" }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
