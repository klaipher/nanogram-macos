import XCTest
import AppKit
import Postbox
import SwiftSignalKit
@testable import TextRecognizing

final class RecognitionFileCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecognitionFileCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.directory)
        super.tearDown()
    }

    private func detected(_ text: String) -> TextRecognizing.Result.Detected {
        let point = "{\"_x\":\"0\",\"_y\":\"0\"}"
        let json = "{\"text\":\"\(text)\",\"_topLeft\":\(point),\"_topRight\":\(point),\"_bottomLeft\":\(point),\"_bottomRight\":\(point),\"_boundingBox\":{\"origin\":\(point),\"size\":{\"_width\":\"0\",\"_height\":\"0\"}}}"
        return try! JSONDecoder().decode(TextRecognizing.Result.Detected.self, from: Data(json.utf8))
    }

    func testEachPhotoIsStoredInItsOwnFile() throws {
        let cache = RecognitionFileCache(directory: self.directory)
        let first = MediaId(namespace: 0, id: 1)
        let second = MediaId(namespace: 0, id: 2)
        cache.set(texts: [self.detected("one")], barcodes: [], stableId: first)
        let firstURL = cache.url(for: first)
        let firstDate = try firstURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        Thread.sleep(forTimeInterval: 1.1)
        cache.set(texts: [self.detected("two")], barcodes: [], stableId: second)
        XCTAssertEqual(try firstURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, firstDate)
        XCTAssertEqual(cache.get(first)?.texts.map { $0.text }, ["one"])
        XCTAssertEqual(cache.get(second)?.texts.map { $0.text }, ["two"])
        XCTAssertNil(cache.get(MediaId(namespace: 0, id: 3)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: self.directory.path).count, 2)
    }

    func testTheCacheKeepsAtMostTheNewestEntries() {
        let cache = RecognitionFileCache(directory: self.directory, maxEntries: 3)
        for id in 0 ..< 6 {
            cache.set(texts: [self.detected("\(id)")], barcodes: [], stableId: MediaId(namespace: 0, id: Int64(id)))
        }
        XCTAssertLessThanOrEqual((try? FileManager.default.contentsOfDirectory(atPath: self.directory.path).count) ?? 0, 3)
        XCTAssertNotNil(cache.get(MediaId(namespace: 0, id: 5)))
    }

    func testSecondViewOfAPhotoComesFromTheCacheWithoutVision() {
        TestBootstrap.installed
        let image = makeCanvas(CGSize(width: 900, height: 500)) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 500))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Cached recognition", attributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]))
            context.textPosition = CGPoint(x: 40, y: 300)
            CTLineDraw(line, context)
            drawQRCode(makeQRCode("https://t.me/telegram", side: 160), in: context, center: CGPoint(x: 760, y: 120))
        }
        let cache = RecognitionFileCache(directory: self.directory)
        let stableId = MediaId(namespace: 0, id: 42)
        func run() -> (TextRecognizing.Result?, Int) {
            let done = DispatchSemaphore(value: 0)
            var finished: TextRecognizing.Result?
            var progress = 0
            let disposable = TextRecognizing.recognize(image, cache: cache, stableId: stableId).start(next: { result in
                switch result {
                case .finish:
                    finished = result
                case .progress:
                    progress += 1
                }
            }, completed: {
                done.signal()
            })
            _ = done.wait(timeout: .now() + 30)
            disposable.dispose()
            return (finished, progress)
        }
        let first = run()
        guard case let .finish(_, texts, barcodes)? = first.0 else {
            return XCTFail("no result")
        }
        XCTAssertTrue(texts.contains(where: { $0.text.contains("Cached") }))
        XCTAssertEqual(barcodes.map { $0.payload }, ["https://t.me/telegram"])
        let second = run()
        guard case let .finish(_, cachedTexts, cachedBarcodes)? = second.0 else {
            return XCTFail("no cached result")
        }
        XCTAssertEqual(second.1, 0)
        XCTAssertEqual(cachedTexts.map { $0.text }, texts.map { $0.text })
        XCTAssertEqual(cachedBarcodes.map { $0.payload }, ["https://t.me/telegram"])
    }

    func testSubjectOutlineReusesOneContext() {
        XCTAssertTrue(TextRecognizing.Subject.outlineContext(for: CGColorSpace(name: CGColorSpace.sRGB)!) === TextRecognizing.Subject.outlineContext(for: CGColorSpace(name: CGColorSpace.sRGB)!))
    }
}
