import Foundation
import SwiftSignalKit

public struct CrashReport: Equatable, Sendable {
    public let url: URL
    public let date: Date
    public let incidentId: String
    public let appVersion: String
    public let buildVersion: String
}

public final class CrashReportStore: @unchecked Sendable {
    private static let rescanDelays: [Double] = [0, 15, 45, 120, 300]
    private static let maxReports = 5

    let directory: URL
    public let isAvailable: Bool
    private let executablePath: String
    private let anonymizedExecutablePath: String
    private let processName: String
    private let handledKey: String
    private let defaults: UserDefaults
    private let queue = Queue(name: "org.telegram.crashReports")
    private let reportsPromise = ValuePromise<[CrashReport]>([], ignoreRepeated: true)
    private var started = false

    public static func userHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            return String(cString: home)
        }
        return NSHomeDirectory()
    }

    public static func defaultDirectory(home: String = CrashReportStore.userHomeDirectory()) -> URL {
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    public static func isSandboxed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        return environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    public init(handledKey: String, directory: URL = CrashReportStore.defaultDirectory(), executablePath: String = Bundle.main.executablePath ?? "", homeDirectory: String = CrashReportStore.userHomeDirectory(), defaults: UserDefaults = .standard, now: Date = Date(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.directory = directory
        self.isAvailable = !CrashReportStore.isSandboxed(environment: environment)
        self.executablePath = executablePath
        if !homeDirectory.isEmpty, executablePath.hasPrefix(homeDirectory + "/") {
            self.anonymizedExecutablePath = "/Users/USER" + executablePath.dropFirst(homeDirectory.count)
        } else {
            self.anonymizedExecutablePath = executablePath
        }
        self.processName = URL(fileURLWithPath: executablePath).lastPathComponent
        self.handledKey = handledKey
        self.defaults = defaults
        if defaults.object(forKey: handledKey) == nil {
            defaults.set(now.timeIntervalSince1970, forKey: handledKey)
        }
    }

    public var reports: Signal<[CrashReport], NoError> {
        self.queue.async {
            guard !self.started else {
                return
            }
            self.started = true
            for delay in CrashReportStore.rescanDelays {
                self.queue.after(delay, { [weak self] in
                    self?.rescan()
                })
            }
        }
        return self.reportsPromise.get()
    }

    public func markHandled(_ reports: [CrashReport]) {
        guard let newest = reports.map({ $0.date }).max() else {
            return
        }
        self.queue.async {
            let handled = self.defaults.double(forKey: self.handledKey)
            self.defaults.set(max(handled, newest.timeIntervalSince1970), forKey: self.handledKey)
            self.rescan()
        }
    }

    public func rescan() {
        self.reportsPromise.set(self.scan())
    }

    public func scan() -> [CrashReport] {
        return self.scan(handledUntil: self.defaults.double(forKey: self.handledKey), limit: CrashReportStore.maxReports)
    }

    public func allReports(limit: Int = 20) -> [CrashReport] {
        return self.scan(handledUntil: 0, limit: limit)
    }

    private func scan(handledUntil handled: Double, limit: Int) -> [CrashReport] {
        guard self.isAvailable, let contents = try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var reports: [CrashReport] = []
        for url in contents where url.pathExtension == "ips" && url.lastPathComponent.hasPrefix(self.processName + "-") {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date.timeIntervalSince1970 > handled else {
                continue
            }
            if let report = self.parse(url: url, date: date) {
                reports.append(report)
            }
        }
        reports.sort(by: { $0.date > $1.date })
        return Array(reports.prefix(limit))
    }

    private func parse(url: URL, date: Date) -> CrashReport? {
        guard let data = try? Data(contentsOf: url), let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
            return nil
        }
        guard let header = (try? JSONSerialization.jsonObject(with: data[data.startIndex ..< newline])) as? [String: Any], header["bug_type"] as? String == "309" else {
            return nil
        }
        guard let body = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any], let procPath = body["procPath"] as? String else {
            return nil
        }
        guard procPath == self.executablePath || procPath == self.anonymizedExecutablePath else {
            return nil
        }
        return CrashReport(url: url, date: date, incidentId: header["incident_id"] as? String ?? url.lastPathComponent, appVersion: header["app_version"] as? String ?? "", buildVersion: header["build_version"] as? String ?? "")
    }
}
