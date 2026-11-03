import AppKit
import XCTest
@testable import ImageCanvasUI

final class EditImageAssetTests: XCTestCase {
    func testAssetCatalogIsCompiledIntoTheBundle() {
        XCTAssertNotNil(Bundle.module.url(forResource: "Assets", withExtension: "car"))
    }

    func testEditorImagesLoad() throws {
        for name in ["Icon_EditImageDraw", "Icon_EditImageCutout", "Icon_EditImageEyedropper", "Icon_EditVideoCrop"] {
            XCTAssertNotNil(Bundle.module.image(forResource: name), name)
        }
        _ = try XCTUnwrap(Bundle.module.image(forResource: "Icon_EditImageDraw"))
        XCTAssertGreaterThan(NSImage(resource: .iconEditImageDraw).size.width, 0)
    }
}
