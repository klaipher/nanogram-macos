import XCTest
@testable import NanogramKit

final class LegacyPreferencesTests: XCTestCase {
    private let domain = "org.klaipher.nanogram.tests.legacy-\(UUID().uuidString)"
    private lazy var defaults = UserDefaults(suiteName: domain) ?? .standard
    private lazy var folder = FileManager.default.temporaryDirectory.appendingPathComponent(domain, isDirectory: true)

    override func setUpWithError() throws {
        XCTAssertNotNil(UserDefaults(suiteName: domain))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeLegacy(_ values: [String: Any]) throws -> URL {
        let url = folder.appendingPathComponent("legacy.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        try data.write(to: url)
        return url
    }

    private func run(_ file: URL, sandboxed: Bool = true) -> LegacyPreferences.Outcome {
        return LegacyPreferences.importOnce(into: defaults, domain: domain, legacyFile: file, isSandboxed: sandboxed)
    }

    func test_legacyFileIsThePreferencesPlistInTheRealHome() {
        XCTAssertEqual(LegacyPreferences.legacyFile(home: "/Users/someone", bundleIdentifier: "org.klaipher.Nanogram").path,
                       "/Users/someone/Library/Preferences/org.klaipher.Nanogram.plist")
    }

    func test_missingKeysAreImportedAndExistingKeysWin() throws {
        defaults.set("container", forKey: "shared")
        let file = try writeLegacy(["shared": "legacy", "enablelogs": true, "_default_account_id": 42])
        XCTAssertEqual(run(file), .imported(2))
        XCTAssertEqual(defaults.string(forKey: "shared"), "container")
        XCTAssertTrue(defaults.bool(forKey: "enablelogs"))
        XCTAssertEqual(defaults.integer(forKey: "_default_account_id"), 42)
    }

    func test_importRunsOnlyOnce() throws {
        let file = try writeLegacy(["enablelogs": true])
        XCTAssertEqual(run(file), .imported(1))
        defaults.removeObject(forKey: "enablelogs")
        XCTAssertEqual(run(file), .alreadyImported)
        XCTAssertNil(defaults.object(forKey: "enablelogs"))
    }

    func test_nothingHappensOutsideTheSandbox() throws {
        let file = try writeLegacy(["enablelogs": true])
        XCTAssertEqual(run(file, sandboxed: false), .notSandboxed)
        XCTAssertNil(defaults.object(forKey: "enablelogs"))
        XCTAssertNil(defaults.object(forKey: LegacyPreferences.importedMarkerKey))
    }

    func test_aMissingFileIsDoneForGood() {
        XCTAssertEqual(run(folder.appendingPathComponent("absent.plist")), .nothingToImport)
        XCTAssertTrue(defaults.bool(forKey: LegacyPreferences.importedMarkerKey))
    }

    func test_anUnreadableFileIsRetriedOnTheNextLaunch() throws {
        let file = try writeLegacy(["enablelogs": true])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertEqual(run(file), .unreadable)
        XCTAssertNil(defaults.object(forKey: LegacyPreferences.importedMarkerKey))
    }

    func test_aCorruptFileIsSkippedAndMarked() throws {
        let file = folder.appendingPathComponent("corrupt.plist")
        try Data("not a plist".utf8).write(to: file)
        XCTAssertEqual(run(file), .nothingToImport)
        XCTAssertTrue(defaults.bool(forKey: LegacyPreferences.importedMarkerKey))
    }

    func test_theMarkerInTheLegacyFileIsNotImported() throws {
        let file = try writeLegacy([LegacyPreferences.importedMarkerKey: true, "enablelogs": true])
        XCTAssertEqual(run(file), .imported(1))
    }
}
