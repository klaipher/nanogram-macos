import XCTest
import CrashRecoveryUI

final class CrashRecoveryLinksTests: XCTestCase {
    private static let englishTable: [String: String] = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Telegram-Mac/en.lproj/Localizable.strings")
        return NSDictionary(contentsOf: url) as? [String: String] ?? [:]
    }()

    func test_directEditionLinksToNanogramReleases() {
        let links = CrashRecoveryLinks.resolve(isAppStoreEdition: false)
        XCTAssertEqual(links.website?.absoluteString, "https://github.com/klaipher/nanogram-releases/releases/latest")
        XCTAssertEqual(links, .nanogramDirect)
    }

    func test_appStoreEditionHasNoGitHubLink() {
        let links = CrashRecoveryLinks.resolve(isAppStoreEdition: true)
        XCTAssertNil(links.website)
        XCTAssertEqual(links.appStore.absoluteString, "macappstore://apps.apple.com/app/id6829268176")
    }

    func test_noEditionLinksToTelegram() {
        for appStoreEdition in [false, true] {
            let links = CrashRecoveryLinks.resolve(isAppStoreEdition: appStoreEdition)
            XCTAssertFalse(links.appStore.absoluteString.contains("747648890"))
            XCTAssertNotEqual(links.website?.host, "macos.telegram.org")
        }
    }

    func test_recoveryTextsDoNotPointToTheTelegramSite() {
        let table = Self.englishTable
        XCTAssertGreaterThan(table.count, 1000)
        for (key, value) in table where key.hasPrefix("CrashRecovery.") {
            XCTAssertFalse(value.contains("macos.telegram.org"), "\(key): \(value)")
        }
        XCTAssertEqual(table["CrashRecovery.OpenWebsite"], "Open GitHub Releases")
        XCTAssertEqual(table["CrashRecovery.WebsiteDetail"], "The newest Nanogram is always on GitHub.")
        XCTAssertEqual(table["CrashRecovery.Reset"], "Reset Local Data…")
    }
}
