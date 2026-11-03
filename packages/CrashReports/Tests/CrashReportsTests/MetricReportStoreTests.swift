import XCTest
@testable import CrashReports

final class MetricReportStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("MetricReportStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.directory)
        super.tearDown()
    }

    private func json(_ value: Int) -> Data {
        return Data("{\"value\":\(value)}".utf8)
    }

    func testSameReportIsStoredOnce() throws {
        let store = MetricReportStore(directory: self.directory)
        XCTAssertTrue(try store.store(self.json(1), kind: .diagnostics, intervalEnd: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(try store.store(self.json(1), kind: .diagnostics, intervalEnd: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(try store.store(self.json(2), kind: .metrics, intervalEnd: Date(timeIntervalSince1970: 200)))
        let reports = store.reports()
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports[0].name.hasPrefix("metrics-200-"))
        XCTAssertTrue(reports[1].name.hasPrefix("diagnostics-100-"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: reports[1].path)), self.json(1))
    }

    func testKeepsTheNewestWithinLimits() throws {
        let store = MetricReportStore(directory: self.directory, maxFiles: 3, maxBytes: 1_000_000)
        for value in 0 ..< 6 {
            try store.store(self.json(value), kind: .metrics, intervalEnd: Date(timeIntervalSince1970: Double(1000 + value)))
        }
        XCTAssertEqual(store.reports().map { $0.name.split(separator: "-")[1] }, ["1005", "1004", "1003"])

        let small = MetricReportStore(directory: self.directory.appendingPathComponent("small"), maxFiles: 10, maxBytes: 30)
        for value in 0 ..< 4 {
            try small.store(self.json(10 + value), kind: .metrics, intervalEnd: Date(timeIntervalSince1970: Double(value)))
        }
        XCTAssertEqual(small.reports().count, 2)
    }

    func testEmptyStore() {
        XCTAssertTrue(MetricReportStore(directory: self.directory).reports().isEmpty)
    }
}

final class MetricReportExportTests: XCTestCase {
    func testExportCopiesEveryReportIntoTheTargetFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MetricReportExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetricReportStore(directory: root.appendingPathComponent("store"))
        try store.store(Data("{\"a\":1}".utf8), kind: .metrics, intervalEnd: Date(timeIntervalSince1970: 10))
        try store.store(Data("{\"b\":2}".utf8), kind: .diagnostics, intervalEnd: Date(timeIntervalSince1970: 20))
        let target = root.appendingPathComponent("export")
        let exported = try store.export(to: target)
        XCTAssertEqual(exported.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted(), store.reports().map { $0.name }.sorted())
    }

    func testCollectorStoresEncodedReportsByKind() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MetricReportCollectorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetricReportStore(directory: directory)
        struct Fake: Encodable { let value: Int }
        XCTAssertTrue(MetricReportCollector.store(Fake(value: 1), kind: .diagnostics, intervalEnd: Date(timeIntervalSince1970: 5), in: store))
        XCTAssertFalse(MetricReportCollector.store(Fake(value: 1), kind: .diagnostics, intervalEnd: Date(timeIntervalSince1970: 5), in: store))
        XCTAssertEqual(store.reports().map { $0.name.split(separator: "-").first.map(String.init) }, ["diagnostics"])
    }
}
