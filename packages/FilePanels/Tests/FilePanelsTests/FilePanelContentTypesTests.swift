import XCTest
import UniformTypeIdentifiers
@testable import FilePanels

@available(macOS 11, *)
final class FilePanelContentTypesTests: XCTestCase {
    func testMediaExtensionsMapToTypes() {
        let types = filePanelContentTypes(for: mediaExts)
        XCTAssertTrue(types.contains(.png))
        XCTAssertTrue(types.contains(.jpeg))
        XCTAssertTrue(types.contains(.mpeg4Movie))
        XCTAssertTrue(types.contains(.quickTimeMovie))
        XCTAssertTrue(types.contains(.gif))
    }

    func testExtensionsAreCaseInsensitive() {
        XCTAssertEqual(filePanelContentTypes(for: ["PNG"]), [.png])
    }

    func testDuplicatesAreCollapsed() {
        XCTAssertEqual(filePanelContentTypes(for: ["jpg", "jpeg"]), [.jpeg])
    }

    func testEmptyInputGivesNoTypes() {
        XCTAssertTrue(filePanelContentTypes(for: []).isEmpty)
    }

    func testUnregisteredExtensionStillYieldsAType() {
        let types = filePanelContentTypes(for: ["tgs"])
        XCTAssertEqual(types.count, 1)
        XCTAssertEqual(types.first?.preferredFilenameExtension ?? "tgs", "tgs")
    }
}
