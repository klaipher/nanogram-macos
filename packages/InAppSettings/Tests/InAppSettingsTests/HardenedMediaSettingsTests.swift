import XCTest
import HardenedMedia
@testable import InAppSettings

final class HardenedMediaSettingsTests: XCTestCase {
    func testLockdownTurnsOffAutomaticDownload() {
        let settings = AutomaticMediaDownloadSettings.defaultSettings
        XCTAssertTrue(settings.automaticDownload)
        XCTAssertFalse(settings.hardened(by: .lockdown).automaticDownload)
        XCTAssertEqual(settings.hardened(by: .lockdown).categories, settings.categories)
    }

    func testAnInactivePolicyKeepsTheDownloadSettings() {
        let settings = AutomaticMediaDownloadSettings.defaultSettings
        XCTAssertEqual(settings.hardened(by: .inactive), settings)
    }

    func testLockdownTurnsOffAutoplayLoopingAndPreloading() {
        let hardened = AutoplayMediaPreferences.defaultSettings.hardened(by: .lockdown)
        XCTAssertFalse(hardened.gifs)
        XCTAssertFalse(hardened.videos)
        XCTAssertFalse(hardened.preloadVideos)
        XCTAssertFalse(hardened.loopAnimatedStickers)
    }

    func testAnInactivePolicyKeepsAutoplay() {
        XCTAssertEqual(AutoplayMediaPreferences.defaultSettings.hardened(by: .inactive), AutoplayMediaPreferences.defaultSettings)
    }
}
