import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramContext

public final class NoopInAppPurchaseManager: InAppPurchaseManagerProtocol {
    public init() {
    }

    public var canMakePayments: Bool {
        return true
    }

    public var availableProducts: Signal<[InAppPurchaseProduct], NoError> {
        return .single([])
    }

    public func restorePurchases(completion: @escaping (InAppPurchaseRestoreState) -> Void) {
        completion(.failed)
    }

    public func finishAllTransactions() {
    }

    public func buyProduct(_ product: InAppPurchaseProduct, quantity: Int32, purpose: AppStoreTransactionPurpose) -> Signal<InAppPurchaseState, InAppPurchaseError> {
        return .fail(.cantMakePayments)
    }
}
