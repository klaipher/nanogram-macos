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
        let logs = self.directory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let ledger = logs.appendingPathComponent("disk-writes.json").path
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

    func testActivationReportsAreRateLimitedAndHourlyAlwaysPasses() {
        var throttle = DiskWriteReportThrottle()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(throttle.shouldReport(reason: "foreground", at: start))
        XCTAssertFalse(throttle.shouldReport(reason: "background", at: start.addingTimeInterval(20)))
        XCTAssertFalse(throttle.shouldReport(reason: "foreground", at: start.addingTimeInterval(299)))
        XCTAssertTrue(throttle.shouldReport(reason: DiskWriteReportThrottle.hourlyReason, at: start.addingTimeInterval(300)))
        XCTAssertFalse(throttle.shouldReport(reason: "background", at: start.addingTimeInterval(400)))
        XCTAssertTrue(throttle.shouldReport(reason: "background", at: start.addingTimeInterval(600)))
    }

    func testClockGoingBackwardsDoesNotSuppressReports() {
        var throttle = DiskWriteReportThrottle()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(throttle.shouldReport(reason: "background", at: start))
        XCTAssertTrue(throttle.shouldReport(reason: "foreground", at: start.addingTimeInterval(-3600)))
    }

    func testReportsInsideTheMinimumIntervalDoNotWriteTheLedgerAgain() {
        let accounting = DiskWriteAccounting()
        accounting.add("logs", bytes: 4096)
        let logs = self.directory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let ledger = logs.appendingPathComponent("disk-writes.json").path
        let reporter = DiskWriteAccountingReporter(accounting: accounting, ledgerPath: ledger)
        let clock = Atomic<Date>(value: Date(timeIntervalSince1970: 2_000_000))
        let lock = NSLock()
        var lines: [String] = []
        let first = expectation(description: "first line")
        let reports = DiskWriteReports(reporter: reporter, log: { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
            first.fulfill()
        }, now: { clock.value })
        reports.report(reason: "background")
        wait(for: [first], timeout: 5.0)
        accounting.add("logs", bytes: 4096)
        clock.value = clock.value.addingTimeInterval(30)
        reports.report(reason: "foreground")
        let queueDrained = expectation(description: "queue drained")
        DispatchQueue(label: "drain").asyncAfter(deadline: .now() + 0.3) { queueDrained.fulfill() }
        wait(for: [queueDrained], timeout: 5.0)
        lock.lock()
        let count = lines.count
        lock.unlock()
        XCTAssertEqual(count, 1)
    }
}

private final class Atomic<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(value: T) {
        self.stored = value
    }

    var value: T {
        get {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.stored
        }
        set {
            self.lock.lock()
            self.stored = newValue
            self.lock.unlock()
        }
    }
}
