import XCTest
import HardenedMedia
import Postbox
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

    func testAStoredDownloadEntryIsReadHardened() {
        let entry = PreferencesEntry(AutomaticMediaDownloadSettings.defaultSettings)
        XCTAssertFalse(AutomaticMediaDownloadSettings.effective(entry, policy: .lockdown).automaticDownload)
        XCTAssertEqual(AutomaticMediaDownloadSettings.effective(entry, policy: .inactive), .defaultSettings)
        XCTAssertFalse(AutomaticMediaDownloadSettings.effective(nil, policy: .lockdown).automaticDownload)
        XCTAssertEqual(AutomaticMediaDownloadSettings.effective(nil, policy: .inactive), .defaultSettings)
    }

    func testAStoredAutoplayEntryIsReadHardened() {
        let entry = PreferencesEntry(AutoplayMediaPreferences.defaultSettings)
        let hardened = AutoplayMediaPreferences.effective(entry, policy: .lockdown)
        XCTAssertFalse(hardened.gifs)
        XCTAssertFalse(hardened.videos)
        XCTAssertFalse(hardened.loopAnimatedStickers)
        XCTAssertEqual(AutoplayMediaPreferences.effective(entry, policy: .inactive), .defaultSettings)
        XCTAssertFalse(AutoplayMediaPreferences.effective(nil, policy: .lockdown).gifs)
    }
}
