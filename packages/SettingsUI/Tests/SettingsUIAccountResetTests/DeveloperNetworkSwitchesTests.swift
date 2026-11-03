import XCTest
import TelegramCore
@testable import SettingsUI

final class DeveloperNetworkSwitchesTests: XCTestCase {
    func testNothingStoredShowsWhatTheCoreRuns() {
        let switches = DeveloperNetworkSwitches(settings: nil)
        XCTAssertFalse(switches.networkFrameworkTransport)
        XCTAssertTrue(switches.downloadsV2)
        XCTAssertEqual(DeveloperNetworkSwitches(settings: .defaultSettings), switches)
    }

    func testStoredValuesWin() {
        var settings = NetworkSettings.defaultSettings
        settings.useNetworkFramework = true
        settings.useExperimentalDownload = false
        let switches = DeveloperNetworkSwitches(settings: settings)
        XCTAssertTrue(switches.networkFrameworkTransport)
        XCTAssertFalse(switches.downloadsV2)
    }

    func testFirstToggleFromDefaultsFlipsTheEffectiveValue() {
        let downloads = DeveloperNetworkSwitches.toggleDownloadsV2(.defaultSettings)
        XCTAssertEqual(downloads.useExperimentalDownload, false)
        XCTAssertFalse(DeveloperNetworkSwitches(settings: downloads).downloadsV2)
        XCTAssertTrue(DeveloperNetworkSwitches(settings: DeveloperNetworkSwitches.toggleDownloadsV2(downloads)).downloadsV2)

        let transport = DeveloperNetworkSwitches.toggleNetworkFrameworkTransport(.defaultSettings)
        XCTAssertEqual(transport.useNetworkFramework, true)
        XCTAssertFalse(DeveloperNetworkSwitches(settings: DeveloperNetworkSwitches.toggleNetworkFrameworkTransport(transport)).networkFrameworkTransport)
    }

    func testTogglesKeepTheOtherSettings() {
        var settings = NetworkSettings.defaultSettings
        settings.backupHostOverride = "example.org"
        settings.useNetworkFramework = true
        let toggled = DeveloperNetworkSwitches.toggleDownloadsV2(settings)
        XCTAssertEqual(toggled.backupHostOverride, "example.org")
        XCTAssertEqual(toggled.useNetworkFramework, true)
    }
}
