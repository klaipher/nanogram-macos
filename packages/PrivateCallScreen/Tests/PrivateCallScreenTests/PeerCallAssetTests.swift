import AppKit
import XCTest
@testable import PrivateCallScreen

final class PeerCallAssetTests: XCTestCase {
    func testAssetCatalogIsCompiledIntoTheBundle() {
        XCTAssertNotNil(Bundle.module.url(forResource: "Assets", withExtension: "car"))
    }

    func testCallScreenImagesLoad() throws {
        for name in ["ic_settings", "ic_add_people", "ic_accept", "ic_decline", "ic_microphoneoff", "ic_mute", "ic_redial", "ic_screen", "ic_video"] {
            XCTAssertNotNil(Bundle.module.image(forResource: name), name)
        }
        _ = try XCTUnwrap(Bundle.module.image(forResource: "ic_settings"))
        XCTAssertGreaterThan(NSImage(resource: .icSettings).size.width, 0)
        XCTAssertGreaterThan(NSImage(resource: .icAddPeople).size.width, 0)
    }
}
