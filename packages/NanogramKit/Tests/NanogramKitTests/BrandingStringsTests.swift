import Foundation
import XCTest
@testable import NanogramKit

final class BrandingStringsTests: XCTestCase {
    private static let englishTable: [String: String] = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Telegram-Mac/en.lproj/Localizable.strings")
        return NSDictionary(contentsOf: url) as? [String: String] ?? [:]
    }()

    func test_everyIdentityKeyExistsInTheBundledEnglishTable() {
        let table = Self.englishTable
        XCTAssertGreaterThan(table.count, 1000)
        for key in BrandingStrings.identityKeys.union(BrandingStrings.englishTexts.keys) {
            let present = BrandingStrings.pluralSuffixes.contains { table[key + $0] != nil }
            XCTAssertTrue(present, "\(key) is not in en.lproj/Localizable.strings")
        }
    }

    func test_englishIdentityStringsNameNanogram() {
        let table = Self.englishTable
        let branded = BrandingStrings.brand(table, languageCode: "en")
        for key in BrandingStrings.identityKeys {
            for suffix in BrandingStrings.pluralSuffixes {
                guard let value = branded[key + suffix] else { continue }
                XCTAssertTrue(value.contains("Nanogram"), "\(key + suffix): \(value)")
                let rest = value.replacingOccurrences(of: "Nanogram or Telegram", with: "")
                    .replacingOccurrences(of: "telegram.org", with: "")
                XCTAssertFalse(rest.contains("Telegram"), "\(key + suffix): \(value)")
            }
        }
    }

    func test_otherKeysStayByteIdentical() {
        let table = Self.englishTable
        let branded = BrandingStrings.brand(table, languageCode: "en")
        XCTAssertEqual(branded.count, table.count)
        let changed = Set(BrandingStrings.identityKeys.flatMap { key in BrandingStrings.pluralSuffixes.map { key + $0 } })
            .union(BrandingStrings.englishTexts.keys)
        for (key, value) in table where !changed.contains(key) {
            XCTAssertEqual(branded[key], value, key)
        }
        XCTAssertEqual(branded["Chat.Service.PeerJoinedTelegram"], table["Chat.Service.PeerJoinedTelegram"])
    }

    func test_loginQRStepOneOffersEitherApp() {
        let english = BrandingStrings.brand(["Login.QR1.Help1": "Open Telegram on your phone"], languageCode: "en")
        XCTAssertEqual(english["Login.QR1.Help1"], "Open Nanogram or Telegram on your phone")
        let german = BrandingStrings.brand(["Login.QR.Help1": "Öffne Telegram auf deinem Telefon"], languageCode: "de")
        XCTAssertEqual(german["Login.QR.Help1"], "Öffne Nanogram / Telegram auf deinem Telefon")
    }

    func test_languagePacksKeepTheirTranslation() {
        let packs: [(String, String, String)] = [
            ("de", "Bei Telegram per QR-Code anmelden", "Bei Nanogram per QR-Code anmelden"),
            ("ru", "Вход в Telegram по QR-коду", "Вход в Nanogram по QR-коду"),
            ("ar", "تسجيل الدخول إلى تيليجرام برمز QR", "تسجيل الدخول إلى Nanogram برمز QR"),
            ("fa", "ورود به تلگرام با کد QR", "ورود به Nanogram با کد QR"),
            ("ko", "QR 코드로 텔레그램에 로그인", "QR 코드로 Nanogram에 로그인"),
        ]
        for (language, value, expected) in packs {
            let branded = BrandingStrings.brand(["Login.QR.Title": value, "Login.QR.Cancel": value], languageCode: language)
            XCTAssertEqual(branded["Login.QR.Title"], expected, language)
            XCTAssertEqual(branded["Login.QR.Cancel"], value, language)
        }
    }

    func test_pluralVariantsAreBranded() {
        let branded = BrandingStrings.brand(["StatusBar.Activate_one": "Show Telegram", "StatusBar.Activate_other": "Show Telegram"], languageCode: "de")
        XCTAssertEqual(branded["StatusBar.Activate_one"], "Show Nanogram")
        XCTAssertEqual(branded["StatusBar.Activate_other"], "Show Nanogram")
    }

    func test_networkProductsAndLinksAreProtected() {
        let value = "Telegram needs Telegram Premium, Telegram Stars and your Telegram account; see telegram.org, macos.telegram.org, @Telegram or t.me/Telegram. Telegram's cache."
        let expected = "Nanogram needs Telegram Premium, Telegram Stars and your Telegram account; see telegram.org, macos.telegram.org, @Telegram or t.me/Telegram. Nanogram's cache."
        XCTAssertEqual(BrandingStrings.rebranded(value, key: "StorageUsage.Calculating", languageCode: "en"), expected)
        XCTAssertEqual(BrandingStrings.rebranded("TelegramMac Telegrams", key: "StorageUsage.Calculating", languageCode: "en"), "TelegramMac Telegrams")
    }

    func test_codeDeliveryTextsAreRewordedInEnglishOnly() {
        let source = ["Login.EnterCodeFromApp": "We've sent the code to the Telegram app on your other devices."]
        XCTAssertEqual(BrandingStrings.brand(source, languageCode: "en")["Login.EnterCodeFromApp"], "We've sent the code to the app on your other devices.")
        XCTAssertEqual(BrandingStrings.brand(source, languageCode: "de"), source)
        XCTAssertNil(BrandingStrings.brand([:], languageCode: "en")["Login.EnterCodeFromApp"])
    }
}
