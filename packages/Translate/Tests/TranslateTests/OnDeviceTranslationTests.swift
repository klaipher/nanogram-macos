import XCTest
import SwiftSignalKit
@testable import Translate

private final class FakeProvider: OnDeviceTranslationProvider {
    var statuses: [String: OnDeviceTranslationStatus] = [:]
    var requests: [(texts: [String], from: String, to: String)] = []
    var failure: Error?

    func status(from: String, to: String) async -> OnDeviceTranslationStatus {
        return self.statuses["\(from)>\(to)"] ?? .unsupported
    }

    func translate(_ texts: [String], from: String, to: String) async throws -> [String] {
        self.requests.append((texts, from, to))
        if let failure = self.failure {
            throw failure
        }
        return texts.map { "[\(to)] " + $0 }
    }
}

private struct Failure: Error {}

final class OnDeviceTranslationTests: XCTestCase {
    private func await<T>(_ signal: Signal<T, NoError>) -> T? {
        let done = expectation(description: "signal")
        var value: T?
        let disposable = signal.start(next: { value = $0 }, completed: { done.fulfill() })
        wait(for: [done], timeout: 5)
        disposable.dispose()
        return value
    }

    func testInstalledPairTranslatesTheWholeBatchOnDevice() {
        let provider = FakeProvider()
        provider.statuses["en>de"] = .installed
        let translation = OnDeviceTranslation(provider: provider)
        let result = self.await(translation.translate(texts: [AnyHashable(1): "Hello", AnyHashable(2): "World"], from: "en", to: "de"))
        XCTAssertEqual(result??[AnyHashable(1)], "[de] Hello")
        XCTAssertEqual(result??[AnyHashable(2)], "[de] World")
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests.first?.texts.sorted(), ["Hello", "World"])
    }

    func testMissingModelsOrUnsupportedPairsGiveNilSoTheServerIsUsed() {
        let provider = FakeProvider()
        provider.statuses["en>de"] = .supported
        let translation = OnDeviceTranslation(provider: provider)
        XCTAssertEqual(self.await(translation.translate(texts: [AnyHashable(1): "Hello"], from: "en", to: "de")) ?? nil, nil)
        XCTAssertEqual(self.await(translation.translate(texts: [AnyHashable(1): "Hello"], from: "en", to: "xx")) ?? nil, nil)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testFailureGivesNil() {
        let provider = FakeProvider()
        provider.statuses["en>de"] = .installed
        provider.failure = Failure()
        let translation = OnDeviceTranslation(provider: provider)
        XCTAssertEqual(self.await(translation.translate(texts: [AnyHashable(1): "Hello"], from: "en", to: "de")) ?? nil, nil)
    }

    func testWithoutProviderNothingIsTranslated() {
        let translation = OnDeviceTranslation(provider: nil)
        XCTAssertEqual(self.await(translation.translate(texts: [AnyHashable(1): "Hello"], from: "en", to: "de")) ?? nil, nil)
    }

    func testSingleTextDetectsTheSourceLanguageWhenItIsUnknown() {
        let provider = FakeProvider()
        provider.statuses["de>en"] = .installed
        let translation = OnDeviceTranslation(provider: provider)
        let result = self.await(translation.translate(text: "Guten Morgen, wie geht es dir heute? Ich hoffe, es geht dir gut.", from: nil, to: "en"))
        XCTAssertEqual(result??.detect, "de")
        XCTAssertEqual(result??.result, "[en] Guten Morgen, wie geht es dir heute? Ich hoffe, es geht dir gut.")
    }

    func testSameLanguageIsNotTranslated() {
        let provider = FakeProvider()
        provider.statuses["en>en"] = .installed
        let translation = OnDeviceTranslation(provider: provider)
        XCTAssertEqual(self.await(translation.translate(texts: [AnyHashable(1): "Hello"], from: "en", to: "en")) ?? nil, nil)
    }

    func testLanguageCodesAreNormalizedForTheSystem() {
        XCTAssertEqual(OnDeviceTranslation.systemLanguageCode("pt-br"), "pt-BR")
        XCTAssertEqual(OnDeviceTranslation.systemLanguageCode("zh-hans"), "zh-Hans")
        XCTAssertEqual(OnDeviceTranslation.systemLanguageCode("nb"), "nb")
        XCTAssertEqual(OnDeviceTranslation.systemLanguageCode("en"), "en")
    }

    func testTheGoogleEndpointIsGone() throws {
        let source = try String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/Translate/Translate.swift").path)
        XCTAssertFalse(source.contains("gtx"))
        XCTAssertFalse(source.contains("User-Agent"))
    }

    func testSystemTranslationOnDevice() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("needs macOS 26")
        }
        let translation = OnDeviceTranslation(provider: SystemTranslationProvider())
        let result = self.await(translation.translate(texts: [AnyHashable(1): "Good morning"], from: "en", to: "de"))
        guard let texts = result ?? nil else {
            throw XCTSkip("en→de models are not installed")
        }
        XCTAssertFalse(texts[AnyHashable(1)]?.isEmpty ?? true)
        XCTAssertNotEqual(texts[AnyHashable(1)], "Good morning")
    }
}
