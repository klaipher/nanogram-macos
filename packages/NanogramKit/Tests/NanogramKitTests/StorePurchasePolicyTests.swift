import Foundation
import XCTest

final class StorePurchasePolicyTests: XCTestCase {
    override func tearDown() {
        StorePurchasePolicy.current = .unrestricted
        super.tearDown()
    }

    func test_storePolicyBlocksEverythingTelegramSells() {
        for entry in StorePurchaseEntryPoint.allCases where entry.sellsTelegramProduct {
            XCTAssertTrue(StorePurchasePolicy.store.blocks(entry), "\(entry)")
            XCTAssertFalse(StorePurchasePolicy.store.allows(entry), "\(entry)")
        }
    }

    func test_storePolicyKeepsWhatTheUserAlreadyHas() {
        let kept: [StorePurchaseEntryPoint] = [.premiumStatus, .premiumFeaturesYouHave, .spendOwnedStars, .sendGiftWithOwnedStars, .receiveOrConvertGift, .botPaymentPhysicalGoods, .spendEarnedRevenueOnAds]
        for entry in kept {
            XCTAssertTrue(StorePurchasePolicy.store.allows(entry), "\(entry)")
        }
    }

    func test_topUpsAndSubscriptionsAreSoldEntryPoints() {
        let sold: [StorePurchaseEntryPoint] = [.premiumSubscription, .premiumGift, .premiumGiveaway, .starsTopUp, .starsGiftToFriends, .tonTopUp, .paidBoost]
        XCTAssertEqual(Set(sold.map { "\($0)" }), Set(StorePurchaseEntryPoint.allCases.filter { $0.sellsTelegramProduct }.map { "\($0)" }))
    }

    func test_unrestrictedPolicyAllowsEverything() {
        for entry in StorePurchaseEntryPoint.allCases {
            XCTAssertTrue(StorePurchasePolicy.unrestricted.allows(entry), "\(entry)")
        }
    }

    func test_oneSwitchTurnsPurchasesBackOn() {
        XCTAssertFalse(StorePurchasePolicy.blocks(.starsTopUp))
        StorePurchasePolicy.current = .store
        XCTAssertTrue(StorePurchasePolicy.blocks(.starsTopUp))
        StorePurchasePolicy.current = StorePurchasePolicy(restrictsPurchases: false)
        XCTAssertFalse(StorePurchasePolicy.blocks(.premiumSubscription))
    }
}
