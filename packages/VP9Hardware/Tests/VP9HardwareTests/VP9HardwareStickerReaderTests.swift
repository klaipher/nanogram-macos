import Foundation
import XCTest
@testable import VP9Hardware

final class VP9HardwareStickerReaderTests: XCTestCase {
    private func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "webm", subdirectory: "Resources"))
        return try Data(contentsOf: url)
    }

    func testReaderProducesPremultipliedBGRAFramesAndLoops() throws {
        try XCTSkipUnless(VP9HardwareStickerReader.probeResult.hasHardwareDecoder, "\(VP9HardwareStickerReader.probeResult)")
        let reader = try XCTUnwrap(VP9HardwareStickerReader(data: try self.data("sticker_vp9"), unpremultiplyAlpha: false))
        XCTAssertEqual(reader.width, 512)
        XCTAssertEqual(reader.frameRate, 30)
        var firstLoop: [Data] = []
        while reader.hasMoreFrames {
            XCTAssertTrue(reader.readFrame { pointer, width, height, bytesPerRow in
                firstLoop.append(Data(bytes: pointer, count: bytesPerRow * height))
                var transparent = 0
                var invalid = 0
                for y in stride(from: 0, to: height, by: 4) {
                    for x in stride(from: 0, to: width, by: 4) {
                        let p = pointer + y * bytesPerRow + x * 4
                        if p[3] == 0 {
                            transparent += 1
                        }
                        if p[0] > p[3] || p[1] > p[3] || p[2] > p[3] {
                            invalid += 1
                        }
                    }
                }
                XCTAssertGreaterThan(transparent, 0)
                XCTAssertEqual(invalid, 0, "premultiplied BGRA")
            })
        }
        XCTAssertEqual(firstLoop.count, reader.frameCount)
        XCTAssertFalse(reader.readFrame { _, _, _, _ in })
        reader.rewind()
        var index = 0
        while reader.hasMoreFrames, index < 10 {
            XCTAssertTrue(reader.readFrame { pointer, _, height, bytesPerRow in
                XCTAssertEqual(Data(bytes: pointer, count: bytesPerRow * height), firstLoop[index], "loop 2 frame \(index)")
            })
            index += 1
        }
    }

    func testBrokenFilesGiveNoReader() {
        XCTAssertNil(VP9HardwareStickerReader(data: Data([0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0]), unpremultiplyAlpha: false))
    }

    func testReadersReleaseTheirSessions() throws {
        try XCTSkipUnless(VP9HardwareStickerReader.probeResult.hasHardwareDecoder)
        let before = VP9HardwareDecoding.activeSessionCount
        var reader = VP9HardwareStickerReader(data: try self.data("sticker_vp9"), unpremultiplyAlpha: false)
        XCTAssertNotNil(reader)
        XCTAssertGreaterThan(VP9HardwareDecoding.activeSessionCount, before)
        reader = nil
        XCTAssertEqual(VP9HardwareDecoding.activeSessionCount, before)
    }

    func testAFullCapGivesNoReaderWithoutReadingTheFile() throws {
        try XCTSkipUnless(VP9HardwareStickerReader.probeResult.hasHardwareDecoder)
        let limit = VP9HardwareDecoding.maxConcurrentSessions
        let free = limit - VP9HardwareDecoding.activeSessionCount
        XCTAssertTrue(VP9HardwareDecoding.acquireSessions(free))
        defer {
            VP9HardwareDecoding.releaseSessions(free)
        }
        let before = VP9HardwareDecoding.stats
        // The path does not exist; with a free slot the read would fail and nothing would be counted.
        XCTAssertNil(VP9HardwareStickerReader(path: "/nonexistent/sticker.webm", unpremultiplyAlpha: false))
        XCTAssertEqual(VP9HardwareDecoding.stats.capMisses - before.capMisses, 1)
    }
}
