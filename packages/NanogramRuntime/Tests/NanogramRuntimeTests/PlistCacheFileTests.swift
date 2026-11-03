import XCTest
@testable import NanogramRuntime

final class PlistCacheFileTests: XCTestCase {
    private struct Map: Codable, Equatable {
        var frames: [Int: Int]
        var fps: Int32
    }

    private var path: String!

    override func setUp() {
        super.setUp()
        self.path = NSTemporaryDirectory() + "plist-cache-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.path)
        super.tearDown()
    }

    private func decode(_ data: Data) -> Map? {
        return try? PropertyListDecoder().decode(Map.self, from: data)
    }

    func testWrittenPlistReadsBackAndIsStoredWithoutAnArchive() throws {
        let map = Map(frames: [1: 10, 2: 20], fps: 60)
        let plist = try PropertyListEncoder().encode(map)
        XCTAssertTrue(PlistCacheFile.write(plist, toPath: self.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: self.path)), plist)
        XCTAssertEqual(PlistCacheFile.read(atPath: self.path, decode: self.decode), map)
    }

    func testAFileWrittenByTheOldKeyedArchiveCodeStillReads() throws {
        let map = Map(frames: [3: 30], fps: 30)
        let plist = try PropertyListEncoder().encode(map)
        let legacy = try NSKeyedArchiver.archivedData(withRootObject: plist, requiringSecureCoding: false)
        try legacy.write(to: URL(fileURLWithPath: self.path))
        XCTAssertEqual(PlistCacheFile.read(atPath: self.path, decode: self.decode), map)
    }

    func testAnEmptyOrMissingFileReadsAsNil() throws {
        XCTAssertNil(PlistCacheFile.read(atPath: self.path, decode: self.decode))
        FileManager.default.createFile(atPath: self.path, contents: nil)
        XCTAssertNil(PlistCacheFile.read(atPath: self.path, decode: self.decode))
    }
}
