import XCTest
import AppKit
import CoreImage
import SwiftSignalKit
import VisionKit
@testable import TextRecognizing

final class LiveTextTests: XCTestCase {
    private func canvas(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return context.makeImage()!
    }

    private func qrImage(_ payload: String, side: CGFloat) -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = filter.outputImage!
        let scaled = output.transformed(by: CGAffineTransform(scaleX: side / output.extent.width, y: side / output.extent.height))
        return CIContext().createCGImage(scaled, from: scaled.extent)!
    }

    private func textImage(_ text: String) -> CGImage {
        return self.canvas(width: 1200, height: 300) { context in
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 90), .foregroundColor: NSColor.black])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: 110)
            CTLineDraw(line, context)
        }
    }

    private func photoWithCode(_ payload: String) -> CGImage {
        let code = self.qrImage(payload, side: 300)
        return self.canvas(width: 800, height: 400) { context in
            context.interpolationQuality = .none
            context.draw(code, in: CGRect(x: 50, y: 50, width: 300, height: 300))
        }
    }

    func testTelegramLinksAreRecognisedInCodes() {
        XCTAssertTrue(LiveTextCode(payload: "tg://resolve?domain=durov", bounds: .zero).isTelegramLink)
        XCTAssertTrue(LiveTextCode(payload: "https://t.me/durov", bounds: .zero).isTelegramLink)
        XCTAssertTrue(LiveTextCode(payload: "t.me/durov", bounds: .zero).isTelegramLink)
        XCTAssertTrue(LiveTextCode(payload: "https://telegram.me/durov", bounds: .zero).isTelegramLink)
        XCTAssertFalse(LiveTextCode(payload: "https://example.com/t.me", bounds: .zero).isTelegramLink)
        XCTAssertFalse(LiveTextCode(payload: "hello", bounds: .zero).isTelegramLink)
        XCTAssertNil(LiveTextCode(payload: "hello", bounds: .zero).link)
        XCTAssertEqual(LiveTextCode(payload: " tg://resolve?domain=durov ", bounds: .zero).link, "tg://resolve?domain=durov")
    }

    func testCodesAreDetectedWithTheirPlaceInThePhoto() throws {
        let codes = LiveTextCodes.detect(in: self.photoWithCode("https://t.me/nanogram"))
        XCTAssertEqual(codes.map { $0.payload }, ["https://t.me/nanogram"])
        let code = try XCTUnwrap(codes.first)
        XCTAssertTrue(code.isTelegramLink)
        XCTAssertLessThan(code.bounds.maxX, 0.5)
        XCTAssertEqual(LiveTextCodes.code(at: CGPoint(x: code.bounds.midX, y: code.bounds.midY), in: codes), code)
        XCTAssertNil(LiveTextCodes.code(at: CGPoint(x: 0.8, y: 0.5), in: codes))
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testAnalysisWaitsForTheDwellSoFlickingRunsNothing() {
        let states = Promise<LiveTextSchedule.State<Int>>(.init(image: nil, isEligible: false))
        var analysed: [Int] = []
        var results: [String?] = []
        let started = Date()
        var firstAnalysisAfter: TimeInterval?
        let disposable = LiveTextSchedule.analysis(states: states.get(), dwell: 1.0, queue: .mainQueue(), analyze: { image -> Signal<String?, NoError> in
            analysed.append(image)
            firstAnalysisAfter = firstAnalysisAfter ?? Date().timeIntervalSince(started)
            return .single("result \(image)")
        }).start(next: { results.append($0) })
        for image in 1 ... 5 {
            states.set(.single(.init(image: image, isEligible: true)))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(analysed, [])
        self.spin(until: { !analysed.isEmpty }, timeout: 20)
        XCTAssertEqual(analysed, [5])
        XCTAssertGreaterThanOrEqual(firstAnalysisAfter ?? 0, 1.0)
        XCTAssertEqual(results.last, "result 5")
        states.set(.single(.init(image: 5, isEligible: false)))
        self.spin(until: { results.last == .some(nil) }, timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(analysed, [5])
        XCTAssertEqual(results.last, .some(nil))
        disposable.dispose()
    }

    func testIneligiblePhotosAreNeverAnalysed() {
        var analysed = 0
        let disposable = LiveTextSchedule.analysis(states: .single(.init(image: 1, isEligible: false)), dwell: 0.05, queue: .mainQueue(), analyze: { _ -> Signal<String?, NoError> in
            analysed += 1
            return .single("x")
        }).start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(analysed, 0)
        disposable.dispose()
    }

    func testVisionKitReadsTextAndCodesOnDevice() throws {
        guard #available(macOS 13.0, *), ImageAnalyzer.isSupported else {
            throw XCTSkip("VisionKit image analysis unavailable")
        }
        let result = try XCTUnwrap(self.analyze(self.textImage("NANOGRAM LIVE TEXT")))
        XCTAssertTrue(result.transcript.uppercased().contains("NANOGRAM"), result.transcript)
        XCTAssertTrue(result.hasContent)
        XCTAssertEqual(result.codes, [])

        let coded = try XCTUnwrap(self.analyze(self.photoWithCode("tg://resolve?domain=nanogram")))
        XCTAssertEqual(coded.codes.map { $0.payload }, ["tg://resolve?domain=nanogram"])
        XCTAssertTrue(coded.hasContent)
        XCTAssertFalse(coded.analysis.hasResults(for: .machineReadableCode))

        let blank = try XCTUnwrap(self.analyze(self.canvas(width: 400, height: 400) { _ in }))
        XCTAssertFalse(blank.hasContent)
    }

    @available(macOS 13.0, *)
    private func analyze(_ image: CGImage) -> LiveTextResult? {
        let done = self.expectation(description: "analysis")
        var value: LiveTextResult?
        let disposable = LiveTextAnalyzer.shared.analyze(image).start(next: { value = $0 }, completed: { done.fulfill() })
        self.wait(for: [done], timeout: 60)
        disposable.dispose()
        return value
    }

    func testOverlayOpensTelegramCodesItselfAndPassesOtherClicksThrough() throws {
        guard #available(macOS 13.0, *) else {
            throw XCTSkip("VisionKit overlay needs macOS 13")
        }
        _ = NSApplication.shared
        let view = LiveTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        XCTAssertNil(view.hitTest(NSPoint(x: 100, y: 100)))
        XCTAssertFalse(view.hasSelectedText)

        let code = LiveTextCode(payload: "https://t.me/nanogram", bounds: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.6))
        let text = LiveTextCode(payload: "plain words", bounds: CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.6))
        view.codes = [code, text]
        var opened: [String] = []
        view.openCode = { opened.append($0.payload) }

        XCTAssertFalse(view.shouldBeginInteraction(at: CGPoint(x: 200, y: 200), types: .dataDetectors))
        XCTAssertFalse(view.shouldBeginInteraction(at: CGPoint(x: 600, y: 200), types: .dataDetectors))
        XCTAssertEqual(opened, ["https://t.me/nanogram", "plain words"])
        XCTAssertTrue(view.shouldBeginInteraction(at: CGPoint(x: 400, y: 380), types: .dataDetectors))
        XCTAssertTrue(view.shouldBeginInteraction(at: CGPoint(x: 200, y: 200), types: .textSelection))
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(view.code(atViewPoint: CGPoint(x: 200, y: 200)), code)
        XCTAssertNil(view.code(atViewPoint: CGPoint(x: 400, y: 380)))
        XCTAssertEqual(view.contentsRect(), CGRect(x: 0, y: 0, width: 1, height: 1))

        view.isActive = false
        XCTAssertTrue(view.overlayView.isHidden)
        XCTAssertNil(view.hitTest(NSPoint(x: 200, y: 200)))
    }

    @available(macOS 13.0, *)
    private func visibleButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, !button.isHiddenOrHasHiddenAncestor, button.frame.width > 0, button.frame.height > 0 {
            return button
        }
        for subview in view.subviews {
            if let button = self.visibleButton(in: subview) {
                return button
            }
        }
        return nil
    }

    @MainActor
    func testLiveTextButtonReceivesClicks() throws {
        guard #available(macOS 13.0, *), ImageAnalyzer.isSupported else {
            throw XCTSkip("VisionKit image analysis unavailable")
        }
        _ = NSApplication.shared
        let result = try XCTUnwrap(self.analyze(self.textImage("NANOGRAM LIVE TEXT")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        window.contentView = container
        let view = LiveTextView(frame: NSRect(x: 100, y: 50, width: 800, height: 533))
        container.addSubview(view)
        view.set(result)
        self.spin(until: { self.visibleButton(in: view.overlayView) != nil }, timeout: 5)

        let button = try XCTUnwrap(self.visibleButton(in: view.overlayView))
        let frame = button.convert(button.bounds, to: container)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let hit = try XCTUnwrap(container.hitTest(center))
        XCTAssertTrue(hit === button || hit.isDescendant(of: button), "\(type(of: hit))")

        XCTAssertFalse(view.overlayView.selectableItemsHighlighted)
        button.performClick(nil)
        XCTAssertTrue(view.overlayView.selectableItemsHighlighted)

        XCTAssertNil(container.hitTest(NSPoint(x: 150, y: 560)).flatMap { $0.isDescendant(of: view) ? $0 : nil })
    }

    func testOldRecognitionFilesAreRemovedOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveTextTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("postbox/media", isDirectory: true)
        let legacy = root.appendingPathComponent("postbox/text-recognition", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("0_1.json"))
        try Data("keep".utf8).write(to: media.appendingPathComponent("photo"))

        XCTAssertTrue(LiveTextLegacyStore.removeFiles(mediaBoxBasePath: media.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent("photo").path))
        XCTAssertFalse(LiveTextLegacyStore.removeFiles(mediaBoxBasePath: media.path))
        XCTAssertEqual(LiveTextLegacyStore.preferencesKey, 1003)
    }
}
