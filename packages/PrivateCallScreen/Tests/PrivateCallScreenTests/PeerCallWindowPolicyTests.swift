import AppKit
import XCTest
@testable import PrivateCallScreen

final class PeerCallWindowPolicyTests: XCTestCase {
    func testRingingWindowCloseDeclinesTheCall() {
        XCTAssertEqual(peerCallCloseAction(for: .ringing), .declineCall)
    }

    func testRecallTerminationsRemoveTheSessionOnClose() {
        XCTAssertEqual(peerCallCloseAction(for: .terminated(.ended(.busy))), .removeSession)
        XCTAssertEqual(peerCallCloseAction(for: .terminated(.error(.disconnected))), .removeSession)
    }

    func testOtherTerminationsAndLiveStatesJustCloseTheWindow() {
        let states: [ExternalPeerCallState.State] = [
            .terminated(nil),
            .terminated(.ended(.hungUp)),
            .terminated(.ended(.missed)),
            .terminated(.error(.generic)),
            .terminating(.ended(.busy)),
            .waiting,
            .requesting(ringing: true),
            .connecting,
            .active(startTime: 0, reception: nil, emoji: ""),
            .reconnecting(startTime: 0, reception: nil, emoji: "")
        ]
        for state in states {
            XCTAssertEqual(peerCallCloseAction(for: state), .closeWindow, "\(state)")
        }
    }

    func testIncomingCardShowsOnlyWhileRinging() {
        XCTAssertTrue(peerCallShowsIncomingCard(makeExternal(.ringing)))
        XCTAssertFalse(peerCallShowsIncomingCard(makeExternal(.ringing, canBeRemoved: true)))
        XCTAssertFalse(peerCallShowsIncomingCard(makeExternal(.connecting)))
        XCTAssertFalse(peerCallShowsIncomingCard(makeExternal(.active(startTime: 0, reception: nil, emoji: ""))))
        XCTAssertFalse(peerCallShowsIncomingCard(makeExternal(.terminated(.ended(.busy)))))
        XCTAssertFalse(peerCallShowsIncomingCard(makeExternal(.requesting(ringing: true))))
    }

    func testPanelJoinsEverySpaceAndFullScreenWithoutActivating() {
        let behavior = IncomingCallPanelConfiguration.collectionBehavior
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.ignoresCycle))
        XCTAssertTrue(IncomingCallPanelConfiguration.styleMask.contains(.nonactivatingPanel))
        XCTAssertGreaterThanOrEqual(IncomingCallPanelConfiguration.level.rawValue, NSWindow.Level.floating.rawValue)
    }

    func testPanelSitsInTheTopRightCorner() {
        let frame = NSMakeRect(0, 0, 1440, 900)
        let origin = IncomingCallPanelConfiguration.origin(in: frame)
        let size = IncomingCallPanelConfiguration.size
        XCTAssertEqual(origin.x + size.width + IncomingCallPanelConfiguration.margin, frame.maxX)
        XCTAssertEqual(origin.y + size.height + IncomingCallPanelConfiguration.margin, frame.maxY)
    }
}
