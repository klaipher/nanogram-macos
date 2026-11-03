import XCTest
import SwiftSignalKit
@testable import InAppSettings

final class AutomaticDownloadDataSavingTests: XCTestCase {
    func testLargeMediaPausesOnlyWhileTheNetworkSavesDataAndTheSettingIsOn() {
        let settings = AutomaticMediaDownloadSettings.defaultSettings
        XCTAssertTrue(settings.respectLowDataMode)
        XCTAssertTrue(settings.pausesLargeMediaDownloads(isSavingData: true))
        XCTAssertFalse(settings.pausesLargeMediaDownloads(isSavingData: false))
        let ignoring = settings.withUpdatedRespectLowDataMode(false)
        XCTAssertFalse(ignoring.pausesLargeMediaDownloads(isSavingData: true))
        XCTAssertNotEqual(ignoring, settings)
    }

    func testSettingsStoredBeforeTheSwitchRespectLowDataMode() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AutomaticMediaDownloadSettings.defaultSettings)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "ldm"))
        let decoded = try JSONDecoder().decode(AutomaticMediaDownloadSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.respectLowDataMode)
        let off = decoded.withUpdatedRespectLowDataMode(false)
        let roundTrip = try JSONDecoder().decode(AutomaticMediaDownloadSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(roundTrip.respectLowDataMode)
    }

    func testTheStateFollowsTheNetworkPath() {
        let path = ValuePromise<Bool>(false, ignoreRepeated: true)
        let saving = AutomaticDownloadDataSaving(networkSignal: path.get())
        XCTAssertFalse(saving.isSavingData)
        path.set(true)
        XCTAssertTrue(saving.isSavingData)
        var values: [Bool] = []
        let disposable = saving.isSavingDataSignal.start(next: { values.append($0) })
        path.set(false)
        XCTAssertFalse(saving.isSavingData)
        XCTAssertEqual(values, [true, false])
        disposable.dispose()
    }
}
