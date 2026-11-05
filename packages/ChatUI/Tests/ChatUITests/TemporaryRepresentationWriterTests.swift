import XCTest
@testable import TelegramMediaUtils

final class TemporaryRepresentationWriterTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "repr-writer-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    func testSuccessfulWriteReturnsTrueAndKeepsFile() {
        let url = URL(fileURLWithPath: directory + "ok")
        let payload = Data([1, 2, 3, 4])
        XCTAssertTrue(writeTemporaryRepresentation(payload, to: url))
        XCTAssertEqual(try? Data(contentsOf: url), payload)
    }

    func testWriteIntoMissingDirectoryReturnsFalseAndLeavesNothing() {
        let url = URL(fileURLWithPath: directory + "missing/child")
        XCTAssertFalse(writeTemporaryRepresentation(Data([1]), to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriteIntoUnwritableDirectoryReturnsFalseAndLeavesNothing() {
        let locked = directory + "locked/"
        try? FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked)
        }
        let url = URL(fileURLWithPath: locked + "file")
        XCTAssertFalse(writeTemporaryRepresentation(Data([1]), to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
