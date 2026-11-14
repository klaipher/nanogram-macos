import XCTest
import AppKit
@testable import NanogramLogExport
@testable import NanogramDebugUI

@MainActor
private final class DeliveryRecorder {
    var messages: [String] = []
    var delivered = 0
    var chatFiles: [URL] = []
    var chatCompletion: (@MainActor @Sendable (NanogramLogChatSendResult) -> Void)?
    var chatAsked: (() -> Void)?
}

final class NanogramLogExportDeliveryTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("NanogramLogExportDeliveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            NanogramLogExportGate.shared.end()
            NanogramLogExportHooks.install(.standalone)
        }
        try? FileManager.default.removeItem(at: self.directory)
    }

    @MainActor
    private func install(_ recorder: DeliveryRecorder, availableKinds: [NanogramLogExportKind] = NanogramLogExportKind.allCases) {
        NanogramLogExportHooks.install(NanogramLogExportHooks(collect: { _ in
            return { [] }
        }, canSendInApp: {
            return true
        }, sendToChat: { files, _, completion in
            recorder.chatFiles = files
            recorder.chatCompletion = completion
            recorder.chatAsked?()
        }, showProgress: { _ in
            return {}
        }, showMessage: { _, text in
            recorder.messages.append(text)
        }, availableKinds: {
            return availableKinds
        }))
    }

    private func writeLogs() throws -> URL {
        let logs = self.directory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("line".utf8).write(to: logs.appendingPathComponent("log-1.txt"))
        return logs
    }

    @MainActor
    private func startChatSend(_ recorder: DeliveryRecorder) throws -> URL {
        let logs = try self.writeLogs()
        let root = self.directory.appendingPathComponent("export", isDirectory: true)
        let asked = self.expectation(description: "chat picker")
        recorder.chatAsked = {
            asked.fulfill()
        }
        let spec = NanogramLogExportSpec(kind: .appLogs, appVersion: "1", buildNumber: "2")
        NanogramLogExportFlow.perform(spec: spec, destination: .nanogram, collect: { [logs] }, window: nil, anchor: nil, root: root, onDelivered: {
            recorder.delivered += 1
        })
        self.wait(for: [asked], timeout: 10)
        XCTAssertEqual(recorder.chatFiles.map(\.lastPathComponent), ["nanogram-logs-app.zip"])
        return try XCTUnwrap(recorder.chatFiles.first)
    }

    @MainActor
    func testChatSendKeepsItsFilesAndTheLockUntilTheUploadFinishes() throws {
        let recorder = DeliveryRecorder()
        self.install(recorder)
        let file = try self.startChatSend(recorder)

        XCTAssertTrue(NanogramLogExportGate.shared.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(recorder.messages, [])
        XCTAssertEqual(recorder.delivered, 0)

        recorder.chatCompletion?(.sent)
        XCTAssertFalse(NanogramLogExportGate.shared.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertEqual(recorder.messages, ["App Logs sent."])
        XCTAssertEqual(recorder.delivered, 1)

        recorder.chatCompletion?(.failed)
        XCTAssertEqual(recorder.messages, ["App Logs sent."])
        XCTAssertEqual(recorder.delivered, 1)
    }

    @MainActor
    func testACancelledChatPickerRemovesTheFilesAndDeliversNothing() throws {
        let recorder = DeliveryRecorder()
        self.install(recorder)
        let file = try self.startChatSend(recorder)
        XCTAssertTrue(NanogramLogExportGate.shared.isRunning)

        recorder.chatCompletion?(.cancelled)
        XCTAssertFalse(NanogramLogExportGate.shared.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertEqual(recorder.messages, [])
        XCTAssertEqual(recorder.delivered, 0)
    }

    @MainActor
    func testAChatPickerClosedWithoutAnAnswerReleasesTheLockAndTheFiles() throws {
        let recorder = DeliveryRecorder()
        self.install(recorder)
        let file = try self.startChatSend(recorder)
        XCTAssertTrue(NanogramLogExportGate.shared.isRunning)

        recorder.chatCompletion = nil
        let released = self.expectation(for: NSPredicate { _, _ in
            return MainActor.assumeIsolated { !NanogramLogExportGate.shared.isRunning }
        }, evaluatedWith: nil)
        self.wait(for: [released], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertEqual(recorder.messages, [])
        XCTAssertEqual(recorder.delivered, 0)
    }

    @MainActor
    func testAFailedUploadRemovesTheFilesAndSaysSo() throws {
        let recorder = DeliveryRecorder()
        self.install(recorder)
        let file = try self.startChatSend(recorder)

        recorder.chatCompletion?(.failed)
        XCTAssertFalse(NanogramLogExportGate.shared.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertEqual(recorder.messages, ["Could not send app logs."])
        XCTAssertEqual(recorder.delivered, 0)
    }

    @MainActor
    func testRunHoldsTheLockUntilItFinishes() {
        let gate = NanogramLogExportGate()
        let run = NanogramLogExportRun(gate: gate, onDelivered: nil)
        XCTAssertNotNil(run)
        XCTAssertTrue(gate.isRunning)
        XCTAssertNil(NanogramLogExportRun(gate: gate, onDelivered: nil))
        run?.finish(delivered: false)
        XCTAssertFalse(gate.isRunning)
        XCTAssertNotNil(NanogramLogExportRun(gate: gate, onDelivered: nil))
    }

    @MainActor
    func testFinishingARunRemovesItsPreparedDirectory() throws {
        for delivered in [true, false] {
            let gate = NanogramLogExportGate()
            let run = try XCTUnwrap(NanogramLogExportRun(gate: gate, onDelivered: nil))
            let prepared = try NanogramLogExportFiles.makeDirectory(root: self.directory)
            try Data("x".utf8).write(to: prepared.appendingPathComponent("nanogram-logs-app.zip"))
            run.attach(directory: prepared)
            run.finish(delivered: delivered)
            XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path), "\(delivered)")
        }
    }

    @MainActor
    func testARunCanLeaveItsFilesForTheUser() throws {
        let run = try XCTUnwrap(NanogramLogExportRun(gate: NanogramLogExportGate(), onDelivered: nil))
        let prepared = try NanogramLogExportFiles.makeDirectory(root: self.directory)
        run.attach(directory: prepared)
        run.finish(delivered: true, removeFiles: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.path))
    }

    @MainActor
    func testOnlyADeliveryCountsAsDelivered() throws {
        let recorder = DeliveryRecorder()
        let failed = try XCTUnwrap(NanogramLogExportRun(gate: NanogramLogExportGate(), onDelivered: {
            recorder.delivered += 1
        }))
        failed.finish(delivered: false)
        XCTAssertEqual(recorder.delivered, 0)
        let delivered = try XCTUnwrap(NanogramLogExportRun(gate: NanogramLogExportGate(), onDelivered: {
            recorder.delivered += 1
        }))
        delivered.finish(delivered: true)
        delivered.finish(delivered: true)
        XCTAssertEqual(recorder.delivered, 1)
    }

    func testChatUploadResult() {
        XCTAssertNil(nanogramLogChatUploadResult([.sent, .pending]))
        XCTAssertNil(nanogramLogChatUploadResult([.failed, .pending]))
        XCTAssertEqual(nanogramLogChatUploadResult([.sent, .sent]), .sent)
        XCTAssertEqual(nanogramLogChatUploadResult([.sent, .failed]), .failed)
        XCTAssertEqual(nanogramLogChatUploadResult([]), .failed)
    }

    func testEmailFallsBackToTheSharePicker() {
        XCTAssertEqual(nanogramLogEmailRoute(hasMailApp: true, canCompose: true), .compose)
        XCTAssertEqual(nanogramLogEmailRoute(hasMailApp: false, canCompose: true), .picker)
        XCTAssertEqual(nanogramLogEmailRoute(hasMailApp: true, canCompose: false), .picker)
        XCTAssertTrue(nanogramLogEmailFailureOffersPicker(NSError(domain: "MailErrorDomain", code: 1)))
        XCTAssertFalse(nanogramLogEmailFailureOffersPicker(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
    }

    @MainActor
    func testAnUnavailableKindSaysWhy() {
        let recorder = DeliveryRecorder()
        self.install(recorder, availableKinds: [.fullReport, .appLogs, .callLogs, .metricKit])
        NanogramLogExportFlow.present(kind: .crashReports, window: nil, anchor: nil, collect: nil, onDelivered: nil)
        XCTAssertEqual(recorder.messages, ["Crash reports aren't available in the App Store edition."])
        XCTAssertFalse(NanogramLogExportGate.shared.isRunning)
    }

    func testUserFacingStringsAreMarkedForLocalization() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var paths = ["Telegram-Mac/packages-integration/hooks/NanogramLogExportHooksInstall.swift"]
        let exportDirectory = "packages/NanogramDebug/Sources/NanogramLogExport"
        for name in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(exportDirectory).path) where name.hasSuffix(".swift") && name != "NanogramReportReadme.swift" && name != "NanogramEnergy.swift" {
            paths.append(exportDirectory + "/" + name)
        }
        let literal = try NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"")
        let sentence = try NSRegularExpression(pattern: "[A-Za-z)…] [A-Za-z]")
        let words: Set<String> = ["Save", "Sending…", "Logs"]
        var checked = 0
        for path in paths {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                let userFacing = literal.matches(in: line, range: range).contains { match in
                    let content = (line as NSString).substring(with: match.range(at: 1))
                    return words.contains(content) || sentence.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil
                }
                if userFacing {
                    checked += 1
                    XCTAssertTrue(line.contains("//TODOLANG"), "\(path): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 15)
    }
}
