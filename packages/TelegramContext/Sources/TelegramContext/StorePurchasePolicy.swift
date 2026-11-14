import Foundation

/// Every place where the app could sell something that Telegram owns (its Premium, Stars and TON products).
/// The Mac App Store edition must not offer any of them (App Review 3.1.1), so each one asks the policy.
public enum StorePurchaseEntryPoint: CaseIterable, Sendable {
    case premiumSubscription
    case premiumGift
    case premiumGiveaway
    case starsTopUp
    case starsGiftToFriends
    case tonTopUp
    case adsTopUp
    case paidBoost

    case premiumStatus
    case premiumFeaturesYouHave
    case spendOwnedStars
    case sendGiftWithOwnedStars
    case receiveOrConvertGift
    case botPaymentPhysicalGoods

    /// True when the entry point sells a Telegram product for money (or leads straight to buying one).
    public var sellsTelegramProduct: Bool {
        switch self {
        case .premiumSubscription, .premiumGift, .premiumGiveaway, .starsTopUp, .starsGiftToFriends, .tonTopUp, .adsTopUp, .paidBoost:
            return true
        case .premiumStatus, .premiumFeaturesYouHave, .spendOwnedStars, .sendGiftWithOwnedStars, .receiveOrConvertGift, .botPaymentPhysicalGoods:
            return false
        }
    }
}

public struct StorePurchasePolicy: Equatable, Sendable {
    public let restrictsPurchases: Bool

    public init(restrictsPurchases: Bool) {
        self.restrictsPurchases = restrictsPurchases
    }

    public static let unrestricted = StorePurchasePolicy(restrictsPurchases: false)
    public static let store = StorePurchasePolicy(restrictsPurchases: true)

    public func allows(_ entryPoint: StorePurchaseEntryPoint) -> Bool {
        return !restrictsPurchases || !entryPoint.sellsTelegramProduct
    }

    public func blocks(_ entryPoint: StorePurchaseEntryPoint) -> Bool {
        return !allows(entryPoint)
    }

    public static let unavailableText = "Buying this isn't available in this version of Nanogram." //TODOLANG

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage = StorePurchasePolicy.unrestricted

    /// The one switch: the app target sets it once at launch (store edition on, direct edition off).
    public static var current: StorePurchasePolicy {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    public static func blocks(_ entryPoint: StorePurchaseEntryPoint) -> Bool {
        return current.blocks(entryPoint)
    }

    public static func allows(_ entryPoint: StorePurchaseEntryPoint) -> Bool {
        return current.allows(entryPoint)
    }
}
