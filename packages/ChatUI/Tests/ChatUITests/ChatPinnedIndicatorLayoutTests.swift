import XCTest
import CoreGraphics
import TGUIKit
@testable import ChatUI

final class ChatPinnedIndicatorLayoutTests: XCTestCase {
    func testTheIndicatorIsCenteredOnTheTitleAndTextLines() {
        let frame = ChatPinnedIndicatorLayout.frame(in: NSSize(width: 600, height: 40), contentHeight: 28)
        XCTAssertEqual(frame, NSRect(x: 22, y: 6, width: 2, height: 28))
        XCTAssertEqual(frame.midY, 20)
    }

    func testTheIndicatorNeverLeavesTheBarOnATallTextBlock() {
        let frame = ChatPinnedIndicatorLayout.frame(in: NSSize(width: 600, height: 40), contentHeight: 60)
        XCTAssertEqual(frame, NSRect(x: 22, y: 5, width: 2, height: 30))
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
        XCTAssertLessThanOrEqual(frame.maxY, 40)
    }

    func testAShortBarKeepsTheIndicatorInsideIt() {
        let frame = ChatPinnedIndicatorLayout.frame(in: NSSize(width: 600, height: 32), contentHeight: 30)
        XCTAssertEqual(frame.height, 22)
        XCTAssertEqual(frame.midY, 16)
    }

    func testOneSegmentFillsTheWholeIndicator() {
        XCTAssertEqual(VerticalParticleListControl.segmentHeight(count: 1, frameHeight: 30, gap: 2), 30)
    }

    func testFewPinsSplitTheIndicatorEvenly() {
        XCTAssertEqual(VerticalParticleListControl.segmentHeight(count: 2, frameHeight: 30, gap: 2), 14)
        XCTAssertEqual(VerticalParticleListControl.segmentHeight(count: 3, frameHeight: 30, gap: 2), 8)
    }

    func testManyPinsKeepThreeSegmentsThatFillTheIndicatorInsteadOfTwelvePointStrips() {
        for count in [4, 7, 50] {
            let height = VerticalParticleListControl.segmentHeight(count: count, frameHeight: 30, gap: 2)
            XCTAssertEqual(height, 8)
            XCTAssertEqual(height * 3 + 2 * 2, 28)
        }
    }

    func testAnIndicatorTooSmallToSplitStillDrawsASegment() {
        XCTAssertGreaterThanOrEqual(VerticalParticleListControl.segmentHeight(count: 9, frameHeight: 3, gap: 2), 1)
    }
    func testTheSelectedSegmentSitsOnItsOwnSlotForEveryPin() {
        let gap: CGFloat = 2
        for frameHeight: CGFloat in [22, 28, 30, 34] {
            for count in 1 ... 50 {
                let height = VerticalParticleListControl.segmentHeight(count: count, frameHeight: frameHeight, gap: gap)
                for index in 0 ..< count {
                    let positions = VerticalParticleListControl.positions(count: count, selectedIndex: index, frameHeight: frameHeight, gap: gap)
                    let itemY = floor(height * CGFloat(index) + CGFloat(index) * gap)
                    XCTAssertEqual(positions.selected, itemY + positions.list, "count \(count) index \(index) height \(frameHeight)")
                    XCTAssertGreaterThanOrEqual(positions.selected, 0, "count \(count) index \(index) height \(frameHeight)")
                    XCTAssertLessThanOrEqual(positions.selected, frameHeight - height, "count \(count) index \(index) height \(frameHeight)")
                }
            }
        }
    }

    func testSteppingBetweenTheLastTwoOfFourPinsMovesTheHighlight() {
        let third = VerticalParticleListControl.positions(count: 4, selectedIndex: 2, frameHeight: 30, gap: 2)
        let fourth = VerticalParticleListControl.positions(count: 4, selectedIndex: 3, frameHeight: 30, gap: 2)
        XCTAssertNotEqual(third.selected, fourth.selected)
        XCTAssertEqual(fourth.selected, 22)
    }
}
