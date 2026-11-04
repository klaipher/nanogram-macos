import Foundation
import DiskWriteAccounting

/// Who wrote how much to disk. The shared Postbox already counts every write (DiskWriteAccounting); this is the part
/// that reads the counters, as the iOS app does in AppDelegate: one log line an hour while the app runs, one when the
/// app goes to the background and one when it comes back, and the per-day totals in `logs/disk-writes.json`, which
/// "Send MetricKit Reports" exports. The log line reaches the file only with "Log to File" on; the ledger is
/// updated either way.
public enum DiskWriteReportSchedule {
    public static let interval: TimeInterval = 60.0 * 60.0
    public static let tolerance: TimeInterval = 60.0
    public static let ledgerFileName = "disk-writes.json"

    /// Where the ledger lives for an app container (next to the app logs, as on iOS).
    public static func ledgerPath(containerPath: String) -> String {
        return containerPath + "/logs/" + ledgerFileName
    }
}

public final class DiskWriteReports {
    private let reporter: DiskWriteAccountingReporter
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "org.klaipher.nanogram.disk-write-reports", qos: .utility)
    private var timer: Foundation.Timer?

    /// Installs the process-wide reporter (the first installation wins) for the ledger at `ledgerPath`.
    public convenience init(ledgerPath: String, log: @escaping (String) -> Void) {
        self.init(reporter: DiskWriteAccountingReporting.install(ledgerPath: ledgerPath), log: log)
    }

    public init(reporter: DiskWriteAccountingReporter, log: @escaping (String) -> Void) {
        self.reporter = reporter
        self.log = log
    }

    deinit {
        self.timer?.invalidate()
    }

    /// Starts the hourly report. Call on the main thread; calling it again restarts the timer.
    public func start() {
        self.timer?.invalidate()
        let timer = Foundation.Timer(timeInterval: DiskWriteReportSchedule.interval, repeats: true, block: { [weak self] _ in
            self?.report(reason: "hourly")
        })
        timer.tolerance = DiskWriteReportSchedule.tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        self.timer?.invalidate()
        self.timer = nil
    }

    /// Accounts what was written since the last report and logs the line. Runs off the calling thread.
    public func report(reason: String) {
        let reporter = self.reporter
        let log = self.log
        self.queue.async {
            // Evaluated here, outside the log call: its message is only built with "Log to File" on, and the
            // ledger must be updated either way.
            let line = reporter.report(reason: reason)
            log(line)
        }
    }
}
