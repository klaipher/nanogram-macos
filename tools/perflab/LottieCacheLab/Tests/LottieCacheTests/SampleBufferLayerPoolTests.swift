import XCTest
import AppKit
import AVFoundation
@testable import TelegramMedia

final class SampleBufferLayerPoolTests: XCTestCase {
    private func drainMain() {
        let done = expectation(description: "main")
        DispatchQueue.main.async {
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    override func setUp() {
        super.setUp()
        clearSampleBufferLayerPoll()
    }

    func testReleasedTileLayersAreReused() {
        let parent = CALayer()
        var holder: SampleBufferLayer? = takeSampleBufferLayer()
        let first = holder!.layer
        parent.addSublayer(first)
        holder = nil
        self.drainMain()
        XCTAssertNil(first.superlayer)
        let second = takeSampleBufferLayer()
        XCTAssertTrue(second.layer === first)
        withExtendedLifetime(second) {}
    }

    func testThePoolIsBounded() {
        var holders = (0 ..< 24).map { _ in takeSampleBufferLayer() }
        let layers = holders.map { $0.layer }
        holders.removeAll()
        self.drainMain()
        let reused = (0 ..< 24).map { _ in takeSampleBufferLayer() }
        let hits = reused.filter { holder in layers.contains { $0 === holder.layer } }.count
        XCTAssertEqual(hits, 16)
        withExtendedLifetime(reused) {}
    }
}
