import XCTest
@testable import ChatExportUI

final class ChatExportRestrictionVerdictTests: XCTestCase {
    func testFailedRefreshFallsBackToCachedDataAndAllowsUnprotectedChat() {
        XCTAssertEqual(chatExportRestrictionVerdict(isFresh: false, peerFound: true, peerRestricted: false, cachedDataRestricted: false), .allowed)
    }
    
    func testFailedRefreshStillRefusesChatThatCachedDataMarksProtected() {
        XCTAssertEqual(chatExportRestrictionVerdict(isFresh: false, peerFound: true, peerRestricted: false, cachedDataRestricted: true), .restricted)
    }
    
    func testFailedRefreshWithoutCachedDataIsUnverified() {
        XCTAssertEqual(chatExportRestrictionVerdict(isFresh: false, peerFound: true, peerRestricted: false, cachedDataRestricted: nil), .unverified)
    }
    
    func testMissingPeerIsUnverifiedEvenAfterFreshRefresh() {
        XCTAssertEqual(chatExportRestrictionVerdict(isFresh: true, peerFound: false, peerRestricted: false, cachedDataRestricted: false), .unverified)
    }
    
    func testProtectedPeerIsRefusedWhenRefreshFailed() {
        XCTAssertEqual(chatExportRestrictionVerdict(isFresh: false, peerFound: true, peerRestricted: true, cachedDataRestricted: nil), .restricted)
    }
    
    func testFreshRefreshOfChatWithoutCachedUserDataIsAllowed() {
        XCTAssertEqual(chatExportRestrictionVerdict(isFresh: true, peerFound: true, peerRestricted: false, cachedDataRestricted: nil), .allowed)
    }
    
    func testFreshRefreshRefusesProtectedChat() {
        XCTAssertEqual(chatExportRestrictionVerdict(isFresh: true, peerFound: true, peerRestricted: false, cachedDataRestricted: true), .restricted)
    }
}
