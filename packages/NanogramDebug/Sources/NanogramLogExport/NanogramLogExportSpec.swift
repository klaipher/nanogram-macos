import Foundation

public enum NanogramLogExportKind: String, CaseIterable, Equatable, Sendable {
    case fullReport
    case appLogs
    case callLogs
    case crashReports
    case metricKit
}

public enum NanogramLogExportPackaging: Equatable, Sendable {
    case archive
    case separateFiles
}

public enum NanogramLogExportDestination: CaseIterable, Equatable, Sendable {
    case nanogram
    case email
    case otherApps
    case saveToFolder

    public var title: String {
        switch self {
        case .nanogram:
            return "Send via Nanogram…" //TODOLANG
        case .email:
            return "Send via Email…" //TODOLANG
        case .otherApps:
            return "Other Apps…" //TODOLANG
        case .saveToFolder:
            return "Save to…" //TODOLANG
        }
    }
}

public func nanogramLogExportDestinations(canSendInApp: Bool) -> [NanogramLogExportDestination] {
    return NanogramLogExportDestination.allCases.filter { $0 != .nanogram || canSendInApp }
}

public struct NanogramLogExportSpec: Equatable, Sendable {
    public let kind: NanogramLogExportKind
    public let what: String
    public let subject: String
    public let fileBaseName: String
    public let packaging: NanogramLogExportPackaging

    public var menuTitle: String {
        return "Send \(self.what)" //TODOLANG
    }

    public var unavailableText: String {
        switch self.kind {
        case .crashReports:
            return "Crash reports aren't available in the App Store edition." //TODOLANG
        case .appLogs, .callLogs, .metricKit, .fullReport:
            return "\(self.what) aren't available in this edition." //TODOLANG
        }
    }

    /// One line shown before sending, for the report that bundles everything.
    public var includedNote: String? {
        switch self.kind {
        case .fullReport:
            return NanogramReport.includedNote
        case .appLogs, .callLogs, .crashReports, .metricKit:
            return nil
        }
    }

    /// The per-day disk-write ledger (DiskWriteAccounting), kept next to the app logs.
    public static let diskWriteLedgerFileName = "disk-writes.json"

    /// Files that go into the export on top of what the collector returns. The MetricKit export carries the
    /// disk-write ledger, as on iOS (the other kinds either have no use for it or already export the whole logs folder).
    public func ledgerSources(logsDirectory: URL) -> [URL] {
        switch self.kind {
        case .metricKit:
            return [logsDirectory.appendingPathComponent(NanogramLogExportSpec.diskWriteLedgerFileName)]
        case .appLogs, .callLogs, .crashReports, .fullReport:
            return []
        }
    }

    public var archiveName: String {
        return self.fileBaseName + ".zip"
    }

    public init(kind: NanogramLogExportKind, appVersion: String, buildNumber: String) {
        let subjectWhat: String
        let tag: String
        switch kind {
        case .fullReport:
            self.what = "Report" //TODOLANG
            subjectWhat = "report" //TODOLANG
            tag = "report"
            self.packaging = .archive
        case .appLogs:
            self.what = "App Logs" //TODOLANG
            subjectWhat = "logs" //TODOLANG
            tag = "app"
            self.packaging = .archive
        case .callLogs:
            self.what = "Call Logs" //TODOLANG
            subjectWhat = "call logs" //TODOLANG
            tag = "calls"
            self.packaging = .archive
        case .crashReports:
            self.what = "Crash Reports" //TODOLANG
            subjectWhat = "crash reports" //TODOLANG
            tag = "crash"
            self.packaging = .separateFiles
        case .metricKit:
            self.what = "MetricKit Reports" //TODOLANG
            subjectWhat = "MetricKit reports" //TODOLANG
            tag = "metrickit"
            self.packaging = .archive
        }
        self.kind = kind
        self.subject = "Nanogram macOS \(subjectWhat) (\(appVersion) (\(buildNumber)))" //TODOLANG
        self.fileBaseName = "nanogram-logs-\(tag)"
    }

    public static func current(_ kind: NanogramLogExportKind, bundle: Bundle = .main) -> NanogramLogExportSpec {
        let info = bundle.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return NanogramLogExportSpec(kind: kind, appVersion: version, buildNumber: build)
    }
}

@MainActor
public final class NanogramLogExportGate {
    public static let shared = NanogramLogExportGate()
    nonisolated public static let didChangeNotification = Notification.Name("NanogramLogExportGateDidChange")

    public private(set) var isRunning = false

    public init() {
    }

    public func begin() -> Bool {
        if self.isRunning {
            return false
        }
        self.isRunning = true
        NotificationCenter.default.post(name: NanogramLogExportGate.didChangeNotification, object: self)
        return true
    }

    public func end() {
        guard self.isRunning else {
            return
        }
        self.isRunning = false
        NotificationCenter.default.post(name: NanogramLogExportGate.didChangeNotification, object: self)
    }
}
