import XCTest
@testable import NanogramLogExport

final class NanogramReportTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    private let device = NanogramReportDevice(model: "Mac15,6", chip: "Apple M3 Pro", systemVersion: "Version 27.2", appVersion: "13.2.0", buildNumber: "202611141200")

    override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("NanogramReportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.directory)
    }

    private func write(_ text: String, _ path: String) throws -> URL {
        let url = self.directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func names(in directory: URL) -> [String] {
        let files = NanogramLogExportFiles.regularFiles(in: directory)
        return files.map { String($0.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1)) }.sorted()
    }

    func testReportIsOneArchiveKindWithANote() {
        let spec = NanogramLogExportSpec(kind: .fullReport, appVersion: "13.2.0", buildNumber: "1")
        XCTAssertEqual(spec.menuTitle, "Send Report")
        XCTAssertEqual(spec.packaging, .archive)
        XCTAssertEqual(spec.archiveName, "nanogram-logs-report.zip")
        XCTAssertEqual(spec.includedNote, NanogramReport.includedNote)
        XCTAssertEqual(NanogramLogExportKind.allCases.first, .fullReport)
        for kind in NanogramLogExportKind.allCases where kind != .fullReport {
            XCTAssertNil(NanogramLogExportSpec(kind: kind, appVersion: "", buildNumber: "").includedNote, "\(kind)")
        }
    }

    func testStagingGroupsEverySectionAndListsThemInTheReadme() throws {
        let logs = self.directory.appendingPathComponent("logs", isDirectory: true)
        _ = try self.write("log", "logs/log-1.txt")
        _ = try self.write("critical", "logs/critlog-1.txt")
        _ = try self.write("{}", "logs/sub/disk-writes.json")
        let call = try self.write("call", "calls/call-1.log")
        let crash = try self.write("crash", "Nanogram-1.ips")
        let sections = [
            NanogramReportSection(folder: "logs", title: "App logs", sources: [logs]),
            NanogramReportSection(folder: "call-logs", title: "Call logs", sources: [call.deletingLastPathComponent(), self.directory.appendingPathComponent("missing")]),
            NanogramReportSection(folder: "crash-reports", title: "Crash reports", sources: [crash]),
            NanogramReportSection(folder: "metrickit", title: "MetricKit reports", sources: []),
        ]
        let root = self.directory.appendingPathComponent("staging", isDirectory: true)
        let staged = try NanogramReport.stage(device: self.device, sections: sections, settings: ["a = on"], in: root)

        XCTAssertEqual(self.names(in: staged), [
            "README.txt",
            "call-logs/calls/call-1.log",
            "crash-reports/Nanogram-1.ips",
            "logs/logs/critlog-1.txt",
            "logs/logs/log-1.txt",
            "logs/logs/sub/disk-writes.json",
            "settings.txt",
        ])
        let readme = try String(contentsOf: staged.appendingPathComponent("README.txt"), encoding: .utf8)
        for expected in ["Nanogram macOS 13.2.0 (202611141200)", "Mac model: Mac15,6", "Chip: Apple M3 Pro", "macOS: Version 27.2", "App logs: 3 file(s)", "Call logs: 1 file(s)", "Crash reports: 1 file(s)", "MetricKit reports: none", "logs/logs/critlog-1.txt", "Not included: message text"] {
            XCTAssertTrue(readme.contains(expected), expected)
        }
        XCTAssertEqual(try String(contentsOf: staged.appendingPathComponent("settings.txt"), encoding: .utf8), "a = on\n")
    }

    func testReportWithNothingStillHasTheReadme() throws {
        let staged = try NanogramReport.stage(device: self.device, sections: [NanogramReportSection(folder: "logs", title: "App logs", sources: [self.directory.appendingPathComponent("missing")])], settings: [], in: self.directory.appendingPathComponent("staging", isDirectory: true))
        XCTAssertEqual(self.names(in: staged), ["README.txt", "settings.txt"])
        let output = try NanogramLogExportFiles.makeDirectory(root: self.directory.appendingPathComponent("out", isDirectory: true))
        let spec = NanogramLogExportSpec(kind: .fullReport, appVersion: "13.2.0", buildNumber: "1")
        XCTAssertEqual(try NanogramLogExportFiles.prepare(spec: spec, sources: [staged], in: output).map(\.lastPathComponent), ["nanogram-logs-report.zip"])
    }

    func testSameNamedFilesFromTwoSourcesDoNotOverwrite() throws {
        let first = try self.write("one", "a/call.log")
        let second = try self.write("two", "b/call.log")
        let staged = try NanogramReport.stage(device: self.device, sections: [NanogramReportSection(folder: "call-logs", title: "Call logs", sources: [first, second])], settings: [], in: self.directory.appendingPathComponent("staging", isDirectory: true))
        XCTAssertEqual(self.names(in: staged).filter { $0.hasPrefix("call-logs/") }, ["call-logs/2-call.log", "call-logs/call.log"])
    }

    func testReportArchiveZipsTheStagedFolderAndStagingIsRemoved() throws {
        let log = try self.write("log", "logs/log-1.txt")
        let root = self.directory.appendingPathComponent("export", isDirectory: true)
        let staged = try NanogramReport.stage(device: self.device, sections: [NanogramReportSection(folder: "logs", title: "App logs", sources: [log])], settings: ["x = 1"], in: NanogramLogExportFiles.stagingRoot(under: root))
        let output = try NanogramLogExportFiles.makeDirectory(root: root)
        let spec = NanogramLogExportSpec(kind: .fullReport, appVersion: "13.2.0", buildNumber: "1")
        let files = try NanogramLogExportFiles.prepare(spec: spec, sources: [staged], in: output)
        let archive = try Data(contentsOf: files[0])
        XCTAssertEqual(Array(archive.prefix(2)), [0x50, 0x4b])
        XCTAssertNotNil(archive.range(of: Data("README.txt".utf8)))
        XCTAssertNotNil(archive.range(of: Data("log-1.txt".utf8)))
        NanogramLogExportFiles.removeStaged([staged, log], root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
    }

    func testSettingsLinesAreSortedAndCarryNoPersonalData() {
        XCTAssertEqual(NanogramReport.settingsLines([("b", "off"), ("a", "on")]), ["a = on", "b = off"])
        XCTAssertFalse(NanogramReport.includedNote.lowercased().contains("telegram"))
    }

    func testDeviceDescribesThisMac() {
        let current = NanogramReportDevice.current()
        XCTAssertFalse(current.model.isEmpty)
        XCTAssertFalse(current.systemVersion.isEmpty)
    }
}
