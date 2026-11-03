import XCTest
@testable import NanogramLogExport

final class NanogramLogExportTests: XCTestCase {
    private let version = "13.1.0"
    private let build = "202611031630"
    private var directory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("NanogramLogExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.directory)
    }

    func testAppLogsSpec() {
        let spec = NanogramLogExportSpec(kind: .appLogs, appVersion: self.version, buildNumber: self.build)
        XCTAssertEqual(spec.what, "App Logs")
        XCTAssertEqual(spec.menuTitle, "Send App Logs")
        XCTAssertEqual(spec.subject, "Nanogram macOS logs (13.1.0 (202611031630))")
        XCTAssertEqual(spec.fileBaseName, "nanogram-logs-app")
        XCTAssertEqual(spec.archiveName, "nanogram-logs-app.zip")
        XCTAssertEqual(spec.packaging, .archive)
    }

    func testEveryKindIsNamedNanogram() {
        var baseNames = Set<String>()
        for kind in NanogramLogExportKind.allCases {
            let spec = NanogramLogExportSpec(kind: kind, appVersion: self.version, buildNumber: self.build)
            XCTAssertEqual(spec.menuTitle, "Send \(spec.what)", "\(kind)")
            XCTAssertTrue(spec.subject.hasPrefix("Nanogram macOS "), "\(kind): \(spec.subject)")
            XCTAssertTrue(spec.subject.hasSuffix(" (13.1.0 (202611031630))"), "\(kind): \(spec.subject)")
            XCTAssertTrue(spec.fileBaseName.hasPrefix("nanogram-logs-"), "\(kind): \(spec.fileBaseName)")
            XCTAssertEqual(spec.archiveName, spec.fileBaseName + ".zip", "\(kind)")
            XCTAssertEqual(spec.fileBaseName, spec.fileBaseName.lowercased(), "\(kind)")
            XCTAssertFalse(spec.fileBaseName.contains(" "), "\(kind)")
            for text in [spec.what, spec.menuTitle, spec.subject, spec.fileBaseName] {
                XCTAssertFalse(text.lowercased().contains("telegram"), "\(kind): \(text)")
            }
            baseNames.insert(spec.fileBaseName)
        }
        XCTAssertEqual(baseNames.count, NanogramLogExportKind.allCases.count)
    }

    func testJSONReportsAreSeparateFiles() {
        XCTAssertEqual(NanogramLogExportKind.allCases.filter { NanogramLogExportSpec(kind: $0, appVersion: "", buildNumber: "").packaging == .separateFiles }, [.crashReports, .metricKit])
    }

    func testDestinations() {
        XCTAssertEqual(nanogramLogExportDestinations(canSendInApp: true), [.nanogram, .email, .otherApps, .saveToFolder])
        XCTAssertEqual(nanogramLogExportDestinations(canSendInApp: false), [.email, .otherApps, .saveToFolder])
        XCTAssertEqual(NanogramLogExportDestination.allCases.map(\.title), ["Send via Nanogram…", "Send via Email…", "Other Apps…", "Save to…"])
        for destination in NanogramLogExportDestination.allCases {
            XCTAssertFalse(destination.title.lowercased().contains("telegram"))
        }
    }

    func testArchiveKindZipsEverySource() throws {
        let logs = self.directory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: logs.appendingPathComponent("log-1.txt"))
        try Data("second".utf8).write(to: logs.appendingPathComponent("log-2.txt"))
        let output = self.directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let spec = NanogramLogExportSpec(kind: .appLogs, appVersion: self.version, buildNumber: self.build)
        let files = try NanogramLogExportFiles.prepare(spec: spec, sources: [logs, self.directory.appendingPathComponent("missing")], in: output)
        XCTAssertEqual(files.map(\.lastPathComponent), ["nanogram-logs-app.zip"])
        let archive = try Data(contentsOf: files[0])
        XCTAssertEqual(Array(archive.prefix(2)), [0x50, 0x4b])
        XCTAssertNotNil(archive.range(of: Data("log-1.txt".utf8)))
        XCTAssertNotNil(archive.range(of: Data("log-2.txt".utf8)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["nanogram-logs-app.zip"])
    }

    func testSeparateFilesKindCopiesEveryReport() throws {
        let first = self.directory.appendingPathComponent("metrics-1-aa.json")
        let second = self.directory.appendingPathComponent("Nanogram-2026-11-03-120000.ips")
        try Data("{}".utf8).write(to: first)
        try Data("{\"bug_type\":\"309\"}\n{}".utf8).write(to: second)
        let output = self.directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let metricKit = try NanogramLogExportFiles.prepare(spec: NanogramLogExportSpec(kind: .metricKit, appVersion: self.version, buildNumber: self.build), sources: [first], in: output)
        XCTAssertEqual(metricKit.map(\.lastPathComponent), ["nanogram-logs-metrickit-metrics-1-aa.json"])
        XCTAssertEqual(try Data(contentsOf: metricKit[0]), Data("{}".utf8))

        let crash = try NanogramLogExportFiles.prepare(spec: NanogramLogExportSpec(kind: .crashReports, appVersion: self.version, buildNumber: self.build), sources: [second], in: output)
        XCTAssertEqual(crash.map(\.lastPathComponent), ["nanogram-logs-crash-Nanogram-2026-11-03-120000.ips"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testNothingToPrepare() throws {
        let empty = self.directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        for kind in NanogramLogExportKind.allCases {
            let spec = NanogramLogExportSpec(kind: kind, appVersion: self.version, buildNumber: self.build)
            XCTAssertEqual(try NanogramLogExportFiles.prepare(spec: spec, sources: [empty, self.directory.appendingPathComponent("missing")], in: self.directory), [], "\(kind)")
        }
    }

    func testExportDirectoriesArePrunedAfterAWeek() throws {
        let now = Date()
        let old = try NanogramLogExportFiles.makeDirectory(root: self.directory)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60)], ofItemAtPath: old.path)
        let recent = try NanogramLogExportFiles.makeDirectory(root: self.directory)
        NanogramLogExportFiles.prune(root: self.directory, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    @MainActor
    func testGateIgnoresRepeatedStarts() {
        let gate = NanogramLogExportGate()
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isRunning)
        XCTAssertFalse(gate.begin())
        gate.end()
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.begin())
    }

    func testNoExportGoesToAFixedPeer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = [
            "packages/CrashReports/Sources/CrashReports/CrashReportStore.swift",
            "packages/SettingsUI/Sources/SettingsUI/GeneralSettingsViewController.swift",
            "packages/SettingsUI/Sources/SettingsUI/DeveloperViewController.swift",
            "packages/SettingsUI/Sources/SettingsUI/DeveloperHooks.swift",
            "Telegram-Mac/packages-integration/hooks/ChatListUIHooksInstall.swift",
            "Telegram-Mac/packages-integration/hooks/DeveloperHooksInstall.swift",
            "Telegram-Mac/packages-integration/hooks/NanogramLogExportHooksInstall.swift",
        ]
        var sources: [String: String] = [:]
        for path in paths {
            sources[path] = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        for directory in ["packages/NanogramDebug/Sources/NanogramLogExport", "packages/NanogramDebug/Sources/NanogramDebugUI"] {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(directory).path) where name.hasSuffix(".swift") {
                let path = directory + "/" + name
                sources[path] = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            }
        }
        XCTAssertTrue(sources.keys.contains("packages/NanogramDebug/Sources/NanogramLogExport/NanogramLogExport.swift"))
        for (path, text) in sources {
            for forbidden in ["resolvePeerByName", "crashReportsBotUsername", "crashReportCouldNotOpenBot", "updater_bot", "CrashReportsBot", "PreviewSenderController", "PeerId(", "EnginePeer.Id("] {
                XCTAssertFalse(text.contains(forbidden), "\(path) contains \(forbidden)")
            }
            if !path.contains("/NanogramLogExport/") {
                for sending in ["NSSharingService", "NSOpenPanel", "NSSavePanel"] {
                    XCTAssertFalse(text.contains(sending), "\(path) shares logs on its own (\(sending)); use NanogramLogExport.present")
                }
            }
        }
        XCTAssertTrue(sources["Telegram-Mac/packages-integration/hooks/ChatListUIHooksInstall.swift", default: ""].contains("NanogramLogExport.present(kind: .crashReports"))
        XCTAssertTrue(sources["packages/SettingsUI/Sources/SettingsUI/GeneralSettingsViewController.swift", default: ""].contains("DeveloperHooks.shared.sendLogs"))
        XCTAssertTrue(sources["packages/SettingsUI/Sources/SettingsUI/DeveloperViewController.swift", default: ""].contains("DeveloperHooks.shared.logExports"))
    }
}
