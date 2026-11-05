import XCTest
import SwiftSignalKit
@testable import TelegramMedia

final class LottieCacheFileTouchTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "trlottie-touch-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func modified(_ path: String) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.modificationDate] as? Date) ?? .distantPast
    }

    private func age(_ path: String, by interval: TimeInterval) {
        let old = Date().addingTimeInterval(-interval)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
    }

    func testFreshFileIsNotTouched() {
        let path = directory + "fresh"
        XCTAssertTrue(createLottieCacheFileIfMissing(atPath: path))
        age(path, by: 3_600)
        let before = modified(path)
        XCTAssertFalse(touchLottieCacheFileIfStale(atPath: path))
        XCTAssertEqual(modified(path), before)
    }

    func testStaleFileIsTouchedOnceThenLeftAlone() {
        let path = directory + "stale"
        XCTAssertTrue(createLottieCacheFileIfMissing(atPath: path))
        age(path, by: 2 * 24 * 3_600)
        XCTAssertTrue(touchLottieCacheFileIfStale(atPath: path))
        XCTAssertLessThan(Date().timeIntervalSince(modified(path)), 60)
        XCTAssertFalse(touchLottieCacheFileIfStale(atPath: path))
    }

    func testMissingFileIsNeitherCreatedNorTouched() {
        let path = directory + "missing"
        XCTAssertFalse(touchLottieCacheFileIfStale(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testCreateKeepsExistingContent() {
        let path = directory + "data"
        FileManager.default.createFile(atPath: path, contents: Data([1, 2, 3]))
        XCTAssertTrue(createLottieCacheFileIfMissing(atPath: path))
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data([1, 2, 3]))
    }

    func testInitDoesNotCreateFilesAndFirstFrameWriteCreatesData() {
        let overrideDirectory = directory + "anim/"
        try? FileManager.default.createDirectory(atPath: overrideDirectory, withIntermediateDirectories: true)
        TRLotData.directoryOverride = overrideDirectory
        defer { TRLotData.directoryOverride = nil }
        let key = LottieAnimationEntryKey(key: .bundle("touch-\(UUID().uuidString)"), size: CGSize(width: 32, height: 32), backingScale: 2)
        let animation = LottieAnimation(compressed: Data(), key: key)
        let supplyment = TRLotFileSupplyment(animation, bufferSize: animation.bufferSize, queue: Queue())
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: overrideDirectory))?.count, 0)
        supplyment.initialize(fps: 30, startFrame: 0, endFrame: 1)
        supplyment.addFrame(nil, (Data(repeating: 7, count: animation.bufferSize), 0))
        _ = supplyment.fps
        XCTAssertTrue(FileManager.default.fileExists(atPath: TRLotData.dataPath(animation, bufferSize: animation.bufferSize)))
    }
}
