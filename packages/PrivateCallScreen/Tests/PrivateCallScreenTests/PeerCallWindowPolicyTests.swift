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

    func testEndingALiveCallHangsUpBeforeTheSessionBecomesRemovable() {
        let states: [ExternalPeerCallState.State] = [
            .ringing,
            .waiting,
            .requesting(ringing: true),
            .connecting,
            .active(startTime: 0, reception: nil, emoji: ""),
            .reconnecting(startTime: 0, reception: nil, emoji: ""),
            .terminating(.ended(.hungUp))
        ]
        for state in states {
            XCTAssertEqual(peerCallEndSteps(for: state), [.hangUp, .markRemovable], "\(state)")
        }
    }

    func testEndingAnEndedCallSendsNothing() {
        XCTAssertEqual(peerCallEndSteps(for: .terminated(.ended(.busy))), [.markRemovable])
        XCTAssertEqual(peerCallEndSteps(for: .terminated(.error(.disconnected))), [.markRemovable])
        XCTAssertEqual(peerCallEndSteps(for: .terminated(nil)), [])
        XCTAssertEqual(peerCallEndSteps(for: .terminated(.ended(.hungUp))), [])
    }

    func testOnlyAnUnremovedRingingCallCountsAsRinging() {
        XCTAssertTrue(peerCallIsRinging(makeExternal(.ringing)))
        XCTAssertFalse(peerCallIsRinging(makeExternal(.ringing, canBeRemoved: true)))
        XCTAssertFalse(peerCallIsRinging(makeExternal(.connecting)))
        XCTAssertFalse(peerCallIsRinging(makeExternal(.active(startTime: 0, reception: nil, emoji: ""))))
        XCTAssertFalse(peerCallIsRinging(makeExternal(.terminated(.ended(.busy)))))
        XCTAssertFalse(peerCallIsRinging(makeExternal(.requesting(ringing: true))))
    }

    func testRingingWindowJoinsEverySpaceAndFullScreenAboveNormalWindows() {
        let normal: NSWindow.CollectionBehavior = [.managed]
        let ringing = peerCallWindowPresentation(ringing: true, normalBehavior: normal, normalLevel: .normal)
        XCTAssertTrue(ringing.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(ringing.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(ringing.collectionBehavior.contains(.managed))
        XCTAssertGreaterThanOrEqual(ringing.level.rawValue, NSWindow.Level.floating.rawValue)
    }

    func testWindowReturnsToNormalBehaviourOnceTheCallIsNotRinging() {
        let normal: NSWindow.CollectionBehavior = [.fullScreenPrimary]
        let presentation = peerCallWindowPresentation(ringing: false, normalBehavior: normal, normalLevel: .normal)
        XCTAssertEqual(presentation, PeerCallWindowPresentation(collectionBehavior: normal, level: .normal))
        XCTAssertFalse(presentation.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(presentation.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testEveryDeclineEntryPointHangsUpBeforeRemoving() {
        // End in the window, closing the ringing window, the card-less notification Decline and the Dock all use these steps.
        XCTAssertEqual(peerCallCloseAction(for: .ringing), .declineCall)
        XCTAssertEqual(peerCallEndSteps(for: .ringing), [.hangUp, .markRemovable])
    }
}
