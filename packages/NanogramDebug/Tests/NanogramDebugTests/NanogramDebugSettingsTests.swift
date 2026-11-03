import XCTest
@testable import NanogramDebug

final class NanogramDebugSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "NanogramDebugSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testToggleReturnsItsDefaultUntilSet() {
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(.toggle(id: "video.hardwareDecoding", section: "Video", title: "Hardware decoding", defaultValue: true))
        XCTAssertTrue(settings.bool("video.hardwareDecoding"))
        settings.set("video.hardwareDecoding", bool: false)
        XCTAssertFalse(settings.bool("video.hardwareDecoding"))
        XCTAssertFalse(NanogramDebugSettings(defaults: defaults).bool("video.hardwareDecoding"))
    }

    func testUnregisteredToggleReadsStoredValueOrFalse() {
        let settings = NanogramDebugSettings(defaults: defaults)
        XCTAssertFalse(settings.bool("unknown"))
        settings.set("unknown", bool: true)
        XCTAssertTrue(settings.bool("unknown"))
    }

    func testChoiceFallsBackToDefaultForUnknownStoredValue() {
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(.choice(id: "display.maxFrameRate", section: "Display", title: "Frame-rate cap", options: [.init(id: "off", title: "Off"), .init(id: "60", title: "60 Hz"), .init(id: "30", title: "30 Hz")], defaultValue: "off"))
        XCTAssertEqual(settings.choice("display.maxFrameRate"), "off")
        settings.set("display.maxFrameRate", choice: "60")
        XCTAssertEqual(settings.choice("display.maxFrameRate"), "60")
        defaults.set("999", forKey: settings.storageKey("display.maxFrameRate"))
        XCTAssertEqual(settings.choice("display.maxFrameRate"), "off")
    }

    func testRegisteringTwiceKeepsOneOptionInRegistrationOrder() {
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(.toggle(id: "a", section: "S", title: "A", defaultValue: false))
        settings.register(.toggle(id: "b", section: "S", title: "B", defaultValue: false))
        settings.register(.toggle(id: "a", section: "S", title: "A again", defaultValue: true))
        XCTAssertEqual(settings.options.map { $0.id }, ["a", "b"])
        XCTAssertEqual(settings.options.first?.title, "A again")
        XCTAssertTrue(settings.bool("a"))
    }

    func testObserversSeeChangesUntilCancelled() {
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(.toggle(id: "x", section: "S", title: "X", defaultValue: false))
        var seen: [Bool] = []
        let observation = settings.observe("x") { settings in
            seen.append(settings.bool("x"))
        }
        settings.set("x", bool: true)
        settings.set("x", bool: true)
        settings.set("x", bool: false)
        observation.cancel()
        settings.set("x", bool: true)
        XCTAssertEqual(seen, [true, false])
    }

    func testResetRestoresDefault() {
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(.toggle(id: "x", section: "S", title: "X", defaultValue: true))
        settings.set("x", bool: false)
        settings.reset("x")
        XCTAssertTrue(settings.bool("x"))
        XCTAssertNil(defaults.object(forKey: settings.storageKey("x")))
    }

    func testSectionsKeepFirstRegistrationOrder() {
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(.toggle(id: "a", section: "Video", title: "A", defaultValue: false))
        settings.register(.toggle(id: "b", section: "Audio", title: "B", defaultValue: false))
        settings.register(.toggle(id: "c", section: "Video", title: "C", defaultValue: false))
        XCTAssertEqual(settings.sections.map { $0.title }, ["Video", "Audio"])
        XCTAssertEqual(settings.sections.map { $0.options.map { $0.id } }, [["a", "c"], ["b"]])
    }
}
