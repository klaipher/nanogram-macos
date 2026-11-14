import XCTest
import SwiftSignalKit
import NanogramDebug
@testable import Translate

private final class StubProvider: OnDeviceTranslationProvider {
    let name: String
    init(_ name: String) {
        self.name = name
    }
    func status(from: String, to: String) async -> OnDeviceTranslationStatus {
        return .installed
    }
    func translate(_ texts: [String], from: String, to: String) async throws -> [String] {
        return texts
    }
}

final class TranslationRoutingTests: XCTestCase {
    private enum Outcome: Equatable {
        case value(String)
        case failed
    }

    private func run(_ steps: [TranslationStep], server: Signal<String?, ServerTranslationFailure>, onDevice: Signal<String?, NoError>, calls: inout [TranslationStep]) -> Outcome? {
        var log: [TranslationStep] = []
        let signal = TranslationRouting.run(steps, server: {
            log.append(.server)
            return server
        }, onDevice: {
            log.append(.onDevice)
            return onDevice
        })
        var outcome: Outcome?
        _ = signal.start(next: { outcome = .value($0) }, error: { _ in outcome = .failed })
        calls = log
        return outcome
    }

    func testAlternativeConfigWithoutOnDeviceUsesTheServer() {
        XCTAssertEqual(TranslationRouting.steps(mode: .alternative, onDeviceAvailable: false), [.server])
        XCTAssertEqual(TranslationRouting.steps(mode: .alternative, onDeviceAvailable: true), [.onDevice, .server])
        XCTAssertEqual(TranslationRouting.steps(mode: .enabled, onDeviceAvailable: false), [.server])
        XCTAssertEqual(TranslationRouting.steps(mode: .enabled, onDeviceAvailable: true), [.server, .onDevice])
    }

    func testOnDeviceNilFallsBackToTheServer() {
        var calls: [TranslationStep] = []
        let outcome = self.run([.onDevice, .server], server: .single("server"), onDevice: .single(nil), calls: &calls)
        XCTAssertEqual(outcome, .value("server"))
        XCTAssertEqual(calls, [.onDevice, .server])
    }

    func testOnDeviceResultSkipsTheServer() {
        var calls: [TranslationStep] = []
        let outcome = self.run([.onDevice, .server], server: .single("server"), onDevice: .single("local"), calls: &calls)
        XCTAssertEqual(outcome, .value("local"))
        XCTAssertEqual(calls, [.onDevice])
    }

    func testServerTryAlternativeMovesToOnDevice() {
        var calls: [TranslationStep] = []
        let outcome = self.run([.server, .onDevice], server: .fail(.tryAlternative), onDevice: .single("local"), calls: &calls)
        XCTAssertEqual(outcome, .value("local"))
        XCTAssertEqual(calls, [.server, .onDevice])
    }

    func testServerErrorFailsWithoutTryingOnDevice() {
        var calls: [TranslationStep] = []
        let outcome = self.run([.server, .onDevice], server: .fail(.other), onDevice: .single("local"), calls: &calls)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(calls, [.server])
    }

    func testNothingLeftFails() {
        var calls: [TranslationStep] = []
        XCTAssertEqual(self.run([.server], server: .single(nil), onDevice: .single("local"), calls: &calls), .failed)
        XCTAssertEqual(self.run([.server], server: .fail(.tryAlternative), onDevice: .single("local"), calls: &calls), .failed)
        XCTAssertEqual(self.run([], server: .single("server"), onDevice: .single("local"), calls: &calls), .failed)
    }

    func testProviderSelectionByOSVersionAndDebugSwitch() {
        let modern = StubProvider("modern")
        let legacy = StubProvider("legacy")
        func pick(_ major: Int, _ flag: Bool) -> String? {
            return (OnDeviceTranslation.selectProvider(osMajorVersion: major, enabled: flag, modern: { modern }, legacy: { legacy }) as? StubProvider)?.name
        }
        XCTAssertNil(pick(15, false))
        XCTAssertNil(pick(25, false))
        XCTAssertEqual(pick(15, true), "legacy")
        XCTAssertEqual(pick(25, true), "legacy")
        XCTAssertNil(pick(26, false))
        XCTAssertNil(pick(27, false))
        XCTAssertEqual(pick(26, true), "modern")
        XCTAssertEqual(pick(27, true), "modern")
        XCTAssertNil(pick(14, true))
    }

    func testDebugSwitchIsOffByDefaultAndReadAtEachCall() {
        let suite = "TranslationRoutingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(OnDeviceTranslation.debugOption)
        guard case let .toggle(defaultValue) = OnDeviceTranslation.debugOption.kind else {
            return XCTFail("toggle expected")
        }
        XCTAssertFalse(defaultValue)

        let legacy = StubProvider("legacy")
        let translation = OnDeviceTranslation(resolveProvider: {
            return OnDeviceTranslation.selectProvider(osMajorVersion: 20, enabled: settings.bool(OnDeviceTranslation.debugOption.id), modern: { nil }, legacy: { legacy })
        })
        XCTAssertFalse(translation.isAvailable)
        settings.set(OnDeviceTranslation.debugOption.id, bool: true)
        XCTAssertTrue(translation.isAvailable)
    }
}
