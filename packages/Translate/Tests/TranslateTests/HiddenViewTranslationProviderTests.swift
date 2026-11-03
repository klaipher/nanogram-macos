import XCTest
import AppKit
@testable import Translate

final class HiddenViewTranslationProviderTests: XCTestCase {
    func testHiddenViewTranslatesAnInstalledPair() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("macOS 15 API")
        }
        let window = await MainActor.run { () -> NSWindow in
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            return window
        }
        let provider = HiddenViewTranslationProvider(timeout: 20, hostWindow: { window })
        guard await provider.status(from: "en", to: "de") == .installed else {
            throw XCTSkip("en>de models not installed")
        }
        let result = try await provider.translate(["Good morning", "Thank you"], from: "en", to: "de")
        XCTAssertEqual(result.count, 2)
        XCTAssertNotEqual(result[0], "Good morning")
        XCTAssertTrue(result[1].lowercased().contains("danke"), result[1])
        let second = try await provider.translate(["Good night"], from: "en", to: "de")
        XCTAssertTrue(second[0].lowercased().contains("nacht"), second[0])
        await MainActor.run { window.close() }
    }

    func testNoWindowFailsSoTheServerIsUsed() async {
        guard #available(macOS 15.0, *) else {
            return
        }
        let provider = HiddenViewTranslationProvider(timeout: 1, hostWindow: { nil })
        let translation = OnDeviceTranslation(provider: provider)
        let installed = await provider.status(from: "en", to: "de") == .installed
        let result: [AnyHashable: String]?? = await withCheckedContinuation { continuation in
            _ = translation.translate(texts: [AnyHashable(0): "Hello"], from: "en", to: "de").start(next: { continuation.resume(returning: $0) })
        }
        if installed {
            XCTAssertEqual(result ?? nil, nil)
        }
    }

    @MainActor
    func testCancellingTheRunningJobStartsTheNextQueuedOne() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("macOS 15 API")
        }
        let model = HiddenTranslationModel()
        var firstResult: [String]?? = .none
        let first = model.enqueue(texts: ["Hello"], from: "en", to: "de", completion: { firstResult = .some($0) })
        _ = model.enqueue(texts: ["Bonjour"], from: "fr", to: "de", completion: { _ in })
        XCTAssertEqual(model.configuration?.source, Locale.Language(identifier: "en"))
        model.cancel(first)
        XCTAssertNotNil(firstResult)
        XCTAssertNil(firstResult!)
        XCTAssertEqual(model.configuration?.source, Locale.Language(identifier: "fr"))
    }

    @MainActor
    func testTheDefaultHostIsADedicatedWindowNotTheKeyWindow() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("macOS 15 API")
        }
        _ = NSApplication.shared
        let appWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        appWindow.isReleasedWhenClosed = false
        appWindow.orderFrontRegardless()
        defer { appWindow.close() }
        let provider = HiddenViewTranslationProvider()
        XCTAssertNotNil(provider.attachedModel())
        let host = try XCTUnwrap(provider.hostView?.window)
        XCTAssertFalse(host === appWindow)
        XCTAssertTrue(appWindow.contentView?.subviews.isEmpty ?? true)
        XCTAssertTrue(host.ignoresMouseEvents)
        XCTAssertFalse(host.canBecomeKey)
        XCTAssertNotNil(provider.attachedModel())
        XCTAssertTrue(provider.hostView?.window === host)
    }

    func testTheDedicatedWindowTranslatesAnInstalledPair() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("macOS 15 API")
        }
        await MainActor.run { _ = NSApplication.shared }
        let provider = HiddenViewTranslationProvider(timeout: 20)
        guard await provider.status(from: "en", to: "de") == .installed else {
            throw XCTSkip("en>de models not installed")
        }
        let result = try await provider.translate(["Thank you"], from: "en", to: "de")
        XCTAssertTrue(result[0].lowercased().contains("danke"), result[0])
    }
}
