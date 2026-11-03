import XCTest
@testable import TGUIKit

final class WindowSaverTests: XCTestCase {
    func testTheSavedFrameRoundTripsThroughASecureArchive() throws {
        let saver = WindowSaver(name: "main", rect: NSRect(x: 10, y: 20, width: 800, height: 600), isFullScreen: true)
        let data = try XCTUnwrap(saver.archivedData())
        let restored = try XCTUnwrap(WindowSaver.unarchive(data))
        XCTAssertEqual(restored.rect, saver.rect)
        XCTAssertEqual(restored.requiredName, "main")
        XCTAssertTrue(restored.isFullScreen)
    }

    func testAFrameSavedByTheOldNonSecureArchiveStillLoads() throws {
        let saver = WindowSaver(name: "legacy", rect: NSRect(x: 1, y: 2, width: 3, height: 4), isFullScreen: false)
        let data = try NSKeyedArchiver.archivedData(withRootObject: saver, requiringSecureCoding: false)
        let restored = try XCTUnwrap(WindowSaver.unarchive(data))
        XCTAssertEqual(restored.rect, saver.rect)
        XCTAssertEqual(restored.requiredName, "legacy")
    }

    func testAnArchiveWithoutANameIsRejectedInsteadOfCrashing() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName(NSStringFromClass(WindowSaver.self), for: NSDictionary.self)
        archiver.encode(NSDictionary(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        XCTAssertNil(WindowSaver.unarchive(archiver.encodedData))
    }
}
