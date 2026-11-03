import Foundation

public enum NanogramLogExportKind: String, CaseIterable, Equatable, Sendable {
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
            return "Send via Nanogram…"
        case .email:
            return "Send via Email…"
        case .otherApps:
            return "Other Apps…"
        case .saveToFolder:
            return "Save to…"
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
        return "Send \(self.what)"
    }

    public var archiveName: String {
        return self.fileBaseName + ".zip"
    }

    public init(kind: NanogramLogExportKind, appVersion: String, buildNumber: String) {
        let subjectWhat: String
        let tag: String
        switch kind {
        case .appLogs:
            self.what = "App Logs"
            subjectWhat = "logs"
            tag = "app"
            self.packaging = .archive
        case .callLogs:
            self.what = "Call Logs"
            subjectWhat = "call logs"
            tag = "calls"
            self.packaging = .archive
        case .crashReports:
            self.what = "Crash Reports"
            subjectWhat = "crash reports"
            tag = "crash"
            self.packaging = .separateFiles
        case .metricKit:
            self.what = "MetricKit Reports"
            subjectWhat = "MetricKit reports"
            tag = "metrickit"
            self.packaging = .separateFiles
        }
        self.kind = kind
        self.subject = "Nanogram macOS \(subjectWhat) (\(appVersion) (\(buildNumber)))"
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
