import XCTest
@testable import NanogramDecoder

final class DecoderQuarantineTests: XCTestCase {
    private func digest(_ value: UInt8) -> Data {
        return DecoderQuarantine.digest(Data([value]))
    }

    func testInsertedDigestIsContained() {
        let quarantine = DecoderQuarantine()
        XCTAssertFalse(quarantine.contains(digest(1)))
        quarantine.insert(digest(1))
        XCTAssertTrue(quarantine.contains(digest(1)))
    }

    func testOldestDigestIsEvictedAtCapacity() {
        let quarantine = DecoderQuarantine(capacity: 2)
        quarantine.insert(digest(1))
        quarantine.insert(digest(2))
        quarantine.insert(digest(3))
        XCTAssertFalse(quarantine.contains(digest(1)))
        XCTAssertTrue(quarantine.contains(digest(2)))
        XCTAssertTrue(quarantine.contains(digest(3)))
    }

    func testRepeatedInsertDoesNotEvict() {
        let quarantine = DecoderQuarantine(capacity: 2)
        quarantine.insert(digest(1))
        quarantine.insert(digest(2))
        quarantine.insert(digest(2))
        quarantine.insert(digest(1))
        XCTAssertTrue(quarantine.contains(digest(1)))
        XCTAssertTrue(quarantine.contains(digest(2)))
    }

    func testCapacityIsAtLeastOne() {
        let quarantine = DecoderQuarantine(capacity: 0)
        quarantine.insert(digest(1))
        XCTAssertTrue(quarantine.contains(digest(1)))
        quarantine.insert(digest(2))
        XCTAssertFalse(quarantine.contains(digest(1)))
    }

    func testConcurrentInsertsStayWithinCapacity() {
        let quarantine = DecoderQuarantine(capacity: 8)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            quarantine.insert(self.digest(UInt8(index % 256)))
            _ = quarantine.contains(self.digest(UInt8(index % 256)))
        }
        var present = 0
        for value in 0..<256 where quarantine.contains(digest(UInt8(value))) {
            present += 1
        }
        XCTAssertEqual(present, 8)
    }
}
