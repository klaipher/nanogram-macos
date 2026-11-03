import Foundation
import SwiftSignalKit
import TelegramCore
import Translate

public final class OnDeviceTranslationService: ExperimentalInternalTranslationService {
    private let translation: OnDeviceTranslation

    public init(translation: OnDeviceTranslation = .shared) {
        self.translation = translation
    }

    public static func install() {
        if OnDeviceTranslation.shared.isAvailable, engineExperimentalInternalTranslationService == nil {
            engineExperimentalInternalTranslationService = OnDeviceTranslationService()
        }
    }

    public func translate(texts: [AnyHashable: String], fromLang: String, toLang: String) -> Signal<[AnyHashable: String]?, NoError> {
        return self.translation.translate(texts: texts, from: fromLang, to: toLang)
    }
}
