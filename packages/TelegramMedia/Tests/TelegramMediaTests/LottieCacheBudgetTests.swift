import XCTest
@testable import TelegramMedia

final class LottieCacheBudgetTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lottie-budget-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func make(_ key: String, liveTime: Int, bytes: Int, age: TimeInterval, now: Date) {
        for suffix in ["map", "data"] {
            let url = directory.appendingPathComponent("\(key)-v71-lz4-bs1024-lt\(liveTime)-\(suffix)")
            FileManager.default.createFile(atPath: url.path, contents: Data(count: suffix == "data" ? bytes : 64))
            try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
    }

    private var names: Set<String> {
        let list = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(list)
    }

    private func has(_ key: String) -> Bool {
        return names.contains { $0.hasPrefix(key + "-") }
    }

    func testChatStickerCachesOutliveAnHour() {
        XCTAssertGreaterThanOrEqual(ASLiveTime.chat.rawValue, 24 * 3600)
        XCTAssertEqual(lottieCacheByteBudget, 512 * 1024 * 1024)
    }

    func testExpiredFilesAreRemovedAndFreshOnesKept() {
        let now = Date()
        make("expired", liveTime: 3_600, bytes: 100, age: 2 * 3600, now: now)
        make("fresh", liveTime: ASLiveTime.chat.rawValue, bytes: 100, age: 2 * 3600, now: now)
        FileManager.default.createFile(atPath: directory.appendingPathComponent("junk").path, contents: Data(count: 4))
        cleanLottieCache(directory: directory.path, now: now, byteBudget: 1 << 30)
        XCTAssertFalse(has("expired"))
        XCTAssertTrue(has("fresh"))
        XCTAssertFalse(names.contains("junk"))
    }

    func testOverBudgetRemovesLeastRecentlyWrittenPairsFirst() {
        let now = Date()
        let lifetime = ASLiveTime.chat.rawValue
        make("oldest", liveTime: lifetime, bytes: 4000, age: 5000, now: now)
        make("older", liveTime: lifetime, bytes: 4000, age: 4000, now: now)
        make("newer", liveTime: lifetime, bytes: 4000, age: 100, now: now)
        make("newest", liveTime: lifetime, bytes: 4000, age: 10, now: now)
        cleanLottieCache(directory: directory.path, now: now, byteBudget: 9000)
        XCTAssertFalse(has("oldest"))
        XCTAssertFalse(has("older"))
        XCTAssertTrue(has("newer"))
        XCTAssertTrue(has("newest"))
        XCTAssertEqual(names.count, 4)
    }

    func testUnderBudgetKeepsEverything() {
        let now = Date()
        make("a", liveTime: ASLiveTime.chat.rawValue, bytes: 1000, age: 100, now: now)
        make("b", liveTime: ASLiveTime.effect.rawValue, bytes: 1000, age: 50, now: now)
        cleanLottieCache(directory: directory.path, now: now, byteBudget: 10_000)
        XCTAssertEqual(names.count, 4)
    }
}
