import XCTest
import CoreGraphics
@testable import ChatUI

final class ChatHeaderLayoutTests: XCTestCase {
    private func area(_ width: CGFloat) -> CGRect {
        CGRect(x: 0, y: 12, width: width, height: 40)
    }

    func testTitleIsCenteredWhenThereIsRoom() {
        let frame = ChatHeaderLayout.titleCapsuleFrame(chatArea: area(1000), leftReserved: 12, rightReserved: 142, contentWidth: 240)
        XCTAssertEqual(frame.midX, 500)
        XCTAssertEqual(frame.width, 240)
        XCTAssertEqual(frame.minY, 12)
        XCTAssertEqual(frame.height, 40)
    }

    func testWiderRightClusterDoesNotShiftTheCenter() {
        let narrowCluster = ChatHeaderLayout.titleCapsuleFrame(chatArea: area(1000), leftReserved: 12, rightReserved: 70, contentWidth: 240)
        let wideCluster = ChatHeaderLayout.titleCapsuleFrame(chatArea: area(1000), leftReserved: 12, rightReserved: 190, contentWidth: 240)
        XCTAssertEqual(narrowCluster.midX, 500)
        XCTAssertEqual(wideCluster.midX, 500)
    }

    func testBackButtonDoesNotShiftTheCenter() {
        let frame = ChatHeaderLayout.titleCapsuleFrame(chatArea: area(900), leftReserved: 62, rightReserved: 142, contentWidth: 240)
        XCTAssertEqual(frame.midX, 450)
    }

    func testChatAreaOffsetIsRespected() {
        let frame = ChatHeaderLayout.titleCapsuleFrame(chatArea: CGRect(x: 300, y: 12, width: 800, height: 40), leftReserved: 12, rightReserved: 142, contentWidth: 240)
        XCTAssertEqual(frame.midX, 700)
    }

    func testLongTitleIsCappedToTheSymmetricRoomAndStaysCentered() {
        let frame = ChatHeaderLayout.titleCapsuleFrame(chatArea: area(800), leftReserved: 12, rightReserved: 142, contentWidth: 2000)
        XCTAssertEqual(frame.width, 800 - 2 * 142)
        XCTAssertEqual(frame.midX, 400)
    }

    func testNarrowWindowFallsBackToTheGapBetweenControls() {
        let frame = ChatHeaderLayout.titleCapsuleFrame(chatArea: area(420), leftReserved: 62, rightReserved: 142, contentWidth: 300)
        XCTAssertEqual(frame.width, 420 - 62 - 142)
        XCTAssertEqual(frame.minX, 62)
        XCTAssertEqual(frame.maxX, 420 - 142)
    }

    func testNarrowWindowKeepsTheCenterWhenTheContentIsSmall() {
        let frame = ChatHeaderLayout.titleCapsuleFrame(chatArea: area(480), leftReserved: 62, rightReserved: 142, contentWidth: 160)
        XCTAssertEqual(frame.width, 160)
        XCTAssertGreaterThanOrEqual(frame.minX, 62)
        XCTAssertLessThanOrEqual(frame.maxX, 480 - 142)
    }

    func testTitleNeverOverlapsTheControlsWhileResizing() {
        for width in stride(from: CGFloat(0), through: 1800, by: 1) {
            for (left, right) in [(CGFloat(12), CGFloat(12)), (12, 70), (62, 70), (12, 190), (62, 190), (62, 12)] {
                for content in [CGFloat(0), 160, 260, 5000] {
                    let frame = ChatHeaderLayout.titleCapsuleFrame(chatArea: area(width), leftReserved: left, rightReserved: right, contentWidth: content)
                    XCTAssertGreaterThanOrEqual(frame.width, 0)
                    XCTAssertLessThanOrEqual(frame.width, content)
                    if width >= left + right {
                        XCTAssertGreaterThanOrEqual(frame.minX, left, "width \(width) left \(left) right \(right) content \(content)")
                        XCTAssertLessThanOrEqual(frame.maxX, width - right, "width \(width) left \(left) right \(right) content \(content)")
                    }
                }
            }
        }
    }

    func testCenteredAccessoryIsBoundedAndAlignedWithTheTitle() {
        let title = ChatHeaderLayout.titleCapsuleFrame(chatArea: area(1000), leftReserved: 12, rightReserved: 142, contentWidth: 240)
        let accessory = ChatHeaderLayout.accessoryFrame(chatArea: area(1000), leftReserved: 12, rightReserved: 12, centered: true)
        XCTAssertEqual(accessory.midX, title.midX)
        XCTAssertEqual(accessory.width, 560)
    }

    func testCenteredAccessoryWidthScalesBetweenTheBounds() {
        XCTAssertEqual(ChatHeaderLayout.accessoryFrame(chatArea: area(600), leftReserved: 12, rightReserved: 12, centered: true).width, 372)
        XCTAssertEqual(ChatHeaderLayout.accessoryFrame(chatArea: area(480), leftReserved: 12, rightReserved: 12, centered: true).width, 320)
    }

    func testAccessoryFallsBackToTheFullWidthWhenNarrow() {
        let frame = ChatHeaderLayout.accessoryFrame(chatArea: area(300), leftReserved: 12, rightReserved: 12, centered: true)
        XCTAssertEqual(frame.minX, 12)
        XCTAssertEqual(frame.width, 276)
    }

    func testAccessoryStaysClearOfTheMonoforumColumn() {
        let frame = ChatHeaderLayout.accessoryFrame(chatArea: area(520), leftReserved: 104, rightReserved: 12, centered: true)
        XCTAssertGreaterThanOrEqual(frame.minX, 104)
        XCTAssertLessThanOrEqual(frame.maxX, 508)
    }

    func testOtherBarsKeepTheFullWidth() {
        let frame = ChatHeaderLayout.accessoryFrame(chatArea: area(1000), leftReserved: 12, rightReserved: 12, centered: false)
        XCTAssertEqual(frame.minX, 12)
        XCTAssertEqual(frame.width, 976)
    }

    func testAccessoryNeverLeavesTheChatColumnWhileResizing() {
        for width in stride(from: CGFloat(0), through: 1800, by: 1) {
            for left in [CGFloat(12), 104] {
                for centered in [true, false] {
                    let frame = ChatHeaderLayout.accessoryFrame(chatArea: area(width), leftReserved: left, rightReserved: 12, centered: centered)
                    XCTAssertGreaterThanOrEqual(frame.width, 0)
                    if width >= left + 12 {
                        XCTAssertGreaterThanOrEqual(frame.minX, left)
                        XCTAssertLessThanOrEqual(frame.maxX, width - 12)
                    }
                }
            }
        }
    }
}
