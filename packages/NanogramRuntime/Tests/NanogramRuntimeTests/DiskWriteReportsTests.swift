import XCTest
import DiskWriteAccounting
@testable import NanogramRuntime

final class DiskWriteReportsTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskWriteReportsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.directory)
    }

    func testLedgerSitsNextToTheAppLogs() {
        XCTAssertEqual(DiskWriteReportSchedule.ledgerPath(containerPath: "/c"), "/c/logs/disk-writes.json")
        XCTAssertEqual(DiskWriteReportSchedule.ledgerFileName, "disk-writes.json")
    }

    func testReportIsHourlyWithTolerance() {
        XCTAssertEqual(DiskWriteReportSchedule.interval, 3600)
        XCTAssertEqual(DiskWriteReportSchedule.tolerance, 60)
    }

    func testReportLogsALineAndWritesTheLedger() {
        let accounting = DiskWriteAccounting()
        accounting.add("logs", bytes: 4096)
        let ledger = self.directory.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("disk-writes.json").path
        let reporter = DiskWriteAccountingReporter(accounting: accounting, ledgerPath: ledger)
        let logged = expectation(description: "line logged")
        let lock = NSLock()
        var lines: [String] = []
        let reports = DiskWriteReports(reporter: reporter, log: { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
            logged.fulfill()
        })
        reports.report(reason: "background")
        wait(for: [logged], timeout: 5.0)
        lock.lock()
        let first = lines.first ?? ""
        lock.unlock()
        XCTAssertTrue(first.hasPrefix("Disk writes (background):"), first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger))
        XCTAssertTrue(((try? String(contentsOfFile: ledger, encoding: .utf8)) ?? "").contains("logs"))
    }

    func testStartAndStopAreRepeatable() {
        let reporter = DiskWriteAccountingReporter(accounting: DiskWriteAccounting(), ledgerPath: nil)
        let reports = DiskWriteReports(reporter: reporter, log: { _ in })
        reports.start()
        reports.start()
        reports.stop()
        reports.stop()
    }
}
