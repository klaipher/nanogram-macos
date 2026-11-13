import XCTest
@testable import NanogramRuntime

final class IncomingCallPolicyTests: XCTestCase {
    func testRingWithNoActiveCallIsPresented() {
        XCTAssertEqual(IncomingCallPolicy.ringAction(ringId: 1, active: nil), .present)
    }

    func testEndedSessionIsReplacedInsteadOfDroppingTheNewCall() {
        XCTAssertEqual(IncomingCallPolicy.ringAction(ringId: 2, active: .p2p(id: 1, isEnded: true)), .replaceEndedSession)
    }

    func testLiveCallsAndGroupCallsAnswerBusy() {
        XCTAssertEqual(IncomingCallPolicy.ringAction(ringId: 2, active: .p2p(id: 1, isEnded: false)), .rejectBusy)
        XCTAssertEqual(IncomingCallPolicy.ringAction(ringId: 2, active: .group), .rejectBusy)
    }

    func testRingOfTheActiveCallIsIgnored() {
        XCTAssertEqual(IncomingCallPolicy.ringAction(ringId: 1, active: .p2p(id: 1, isEnded: false)), .ignore)
        XCTAssertEqual(IncomingCallPolicy.ringAction(ringId: 1, active: .p2p(id: 1, isEnded: true)), .ignore)
    }

    func testLedgerPresentsEachRingOnce() {
        var ledger = IncomingCallRingLedger<Int>()
        XCTAssertEqual(ledger.decide(ringId: 1, active: nil), .present)
        XCTAssertEqual(ledger.decide(ringId: 1, active: nil), .ignore)
        XCTAssertEqual(ledger.decide(ringId: 1, active: .p2p(id: 1, isEnded: false)), .ignore)
    }

    func testLedgerAnswersBusyOnlyOnce() {
        var ledger = IncomingCallRingLedger<Int>()
        XCTAssertEqual(ledger.decide(ringId: 2, active: .group), .rejectBusy)
        XCTAssertEqual(ledger.decide(ringId: 2, active: .group), .ignore)
    }

    func testLedgerForgetsRingsThatAreGone() {
        var ledger = IncomingCallRingLedger<Int>()
        _ = ledger.decide(ringId: 1, active: nil)
        _ = ledger.decide(ringId: 2, active: nil)
        ledger.prune(keeping: [2])
        XCTAssertEqual(ledger.decide(ringId: 1, active: nil), .present)
        XCTAssertEqual(ledger.decide(ringId: 2, active: nil), .ignore)
    }

    func testRingIsReadyWhenSyncFinishedOrGraceElapsed() {
        XCTAssertTrue(IncomingCallPolicy.isRingReady(isUpdating: false, graceElapsed: false))
        XCTAssertFalse(IncomingCallPolicy.isRingReady(isUpdating: true, graceElapsed: false))
        XCTAssertTrue(IncomingCallPolicy.isRingReady(isUpdating: true, graceElapsed: true))
    }

    func testGraceAndTimeoutStayShort() {
        XCTAssertLessThanOrEqual(IncomingCallPolicy.ringGateGrace, 2)
        XCTAssertLessThanOrEqual(IncomingCallPolicy.sessionDataTimeout, 3)
    }

    func testIncomingWindowsDoNotAnimate() {
        XCTAssertFalse(IncomingCallPolicy.shouldAnimateWindow(isIncoming: true, reduceMotion: false))
        XCTAssertFalse(IncomingCallPolicy.shouldAnimateWindow(isIncoming: false, reduceMotion: true))
        XCTAssertTrue(IncomingCallPolicy.shouldAnimateWindow(isIncoming: false, reduceMotion: false))
    }

    func testCallerIsHiddenWhenLockedOrPreviewsAreOff() {
        XCTAssertTrue(IncomingCallPolicy.hidesCaller(isLocked: true, previewsEnabled: true))
        XCTAssertTrue(IncomingCallPolicy.hidesCaller(isLocked: false, previewsEnabled: false))
        XCTAssertFalse(IncomingCallPolicy.hidesCaller(isLocked: false, previewsEnabled: true))
    }

    func testDisplayTitleFallsBackToTheAppName() {
        XCTAssertEqual(IncomingCallPolicy.displayTitle(callerName: "Alice", hidesCaller: false, appName: "Nanogram"), "Alice")
        XCTAssertEqual(IncomingCallPolicy.displayTitle(callerName: "Alice", hidesCaller: true, appName: "Nanogram"), "Nanogram")
        XCTAssertEqual(IncomingCallPolicy.displayTitle(callerName: nil, hidesCaller: false, appName: "Nanogram"), "Nanogram")
        XCTAssertEqual(IncomingCallPolicy.displayTitle(callerName: "", hidesCaller: false, appName: "Nanogram"), "Nanogram")
    }
}
