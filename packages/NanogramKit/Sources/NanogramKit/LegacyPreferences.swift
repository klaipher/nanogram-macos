import Foundation

public enum LegacyPreferences {
    public static let importedMarkerKey = "nanogram.legacyPreferencesImported"

    public enum Outcome: Equatable, Sendable {
        case notSandboxed
        case alreadyImported
        case nothingToImport
        case unreadable
        case imported(Int)
    }

    public static var isSandboxed: Bool {
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    public static func userHomeDirectory() -> String? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return nil
        }
        return String(cString: directory)
    }

    public static func legacyFile(home: String, bundleIdentifier: String) -> URL {
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent(bundleIdentifier + ".plist")
    }

    @discardableResult
    public static func importOnce(into defaults: UserDefaults, domain: String, legacyFile: URL, isSandboxed: Bool) -> Outcome {
        guard isSandboxed else {
            return .notSandboxed
        }
        guard !defaults.bool(forKey: importedMarkerKey) else {
            return .alreadyImported
        }
        let data: Data
        do {
            data = try Data(contentsOf: legacyFile)
        } catch CocoaError.fileReadNoSuchFile {
            defaults.set(true, forKey: importedMarkerKey)
            return .nothingToImport
        } catch {
            return .unreadable
        }
        guard let legacy = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            defaults.set(true, forKey: importedMarkerKey)
            return .nothingToImport
        }
        let existing = Set(defaults.persistentDomain(forName: domain)?.keys.map { $0 } ?? [])
        var count = 0
        for (key, value) in legacy where key != importedMarkerKey && !existing.contains(key) {
            defaults.set(value, forKey: key)
            count += 1
        }
        defaults.set(true, forKey: importedMarkerKey)
        return .imported(count)
    }
}
