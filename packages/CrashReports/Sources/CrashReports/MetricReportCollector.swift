import Foundation
import MetricKit

@available(macOS 12.0, *)
public final class MetricReportCollector: NSObject, MXMetricManagerSubscriber {
    public static let shared = MetricReportCollector()

    private let store: MetricReportStore
    private var started = false
    private var metricManager: AnyObject?
    private var metricTasks: [Task<Void, Never>] = []

    public init(store: MetricReportStore = .shared) {
        self.store = store
        super.init()
    }

    public func start() {
        precondition(Thread.isMainThread)
        guard !self.started else {
            return
        }
        self.started = true
        if #available(macOS 27.0, *) {
            self.startMetricManager()
        } else {
            let manager = MXMetricManager.shared
            manager.add(self)
            let pastMetricPayloads = manager.pastPayloads
            let pastDiagnosticPayloads = manager.pastDiagnosticPayloads
            DispatchQueue.global(qos: .utility).async {
                self.didReceive(pastMetricPayloads)
                self.didReceive(pastDiagnosticPayloads)
            }
        }
    }

    @available(macOS 27.0, *)
    private func startMetricManager() {
        let metricManager = MetricManager()
        self.metricManager = metricManager
        let store = self.store
        self.metricTasks.append(Task.detached(priority: .utility) {
            for await report in metricManager.metricReports {
                MetricReportCollector.store(report, kind: .metrics, intervalEnd: report.timeRange.end, in: store)
            }
        })
        self.metricTasks.append(Task.detached(priority: .utility) {
            for await report in metricManager.diagnosticReports {
                MetricReportCollector.store(report, kind: .diagnostics, intervalEnd: report.timeRange.end, in: store)
            }
        })
    }

    @discardableResult
    static func store<T: Encodable>(_ report: T, kind: MetricReportStore.Kind, intervalEnd: Date, in store: MetricReportStore) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try store.store(try encoder.encode(report), kind: kind, intervalEnd: intervalEnd)
        } catch {
            NSLog("MetricKit: could not store a %@ report (%@)", kind.rawValue, String(describing: type(of: error)))
            return false
        }
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            _ = try? self.store.store(payload.jsonRepresentation(), kind: .metrics, intervalEnd: payload.timeStampEnd)
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            _ = try? self.store.store(payload.jsonRepresentation(), kind: .diagnostics, intervalEnd: payload.timeStampEnd)
        }
    }
}
