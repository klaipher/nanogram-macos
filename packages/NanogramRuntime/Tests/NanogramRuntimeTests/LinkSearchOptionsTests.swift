import XCTest
import NanogramDebug
import NanogramFeatures
@testable import NanogramRuntime

// The Mac side of the shared link-hygiene and search-operator code: the switches and their defaults, and the shared data
// (klaipher/nanogram-deps data/, reached through the core's shared/ submodule). The logic itself is tested by the
// NanogramFeatures package (the iOS core's tests, compiled through symlinks).
final class LinkSearchOptionsTests: XCTestCase {
    private func sharedData(_ name: String, file: StaticString = #filePath) throws -> Data {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("submodules/telegram-ios/shared/data/\(name)")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("shared/data/\(name) is not reachable (the core's shared/ submodule is not checked out)")
        }
        return data
    }

    func testBothLinkOptionsAreOffByDefaultAndUserFacing() {
        let defaults = UserDefaults(suiteName: "LinkSearchOptionsTests.\(UUID().uuidString)")!
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(LinkHygiene.stripOption)
        settings.register(LinkHygiene.confirmOption)
        XCTAssertFalse(LinkHygiene.stripsTracking(in: settings))
        XCTAssertFalse(LinkHygiene.confirmsTelegramLinks(in: settings))
        XCTAssertTrue(LinkHygiene.stripOption.isUserFacing)
        XCTAssertTrue(LinkHygiene.confirmOption.isUserFacing)
        settings.set(LinkHygiene.stripOptionId, bool: true)
        XCTAssertTrue(LinkHygiene.stripsTracking(in: settings))
    }

    func testSearchOperatorsAreOnByDefaultAndUserFacing() {
        let defaults = UserDefaults(suiteName: "LinkSearchOptionsTests.\(UUID().uuidString)")!
        let settings = NanogramDebugSettings(defaults: defaults)
        settings.register(SearchOperators.debugOption)
        XCTAssertTrue(SearchOperators.isEnabled(in: settings))
        XCTAssertTrue(SearchOperators.debugOption.isUserFacing)
        settings.set(SearchOperators.optionId, bool: false)
        XCTAssertFalse(SearchOperators.isEnabled(in: settings))
    }

    func testTheMacParsesOnlyTheTypesItCanMapToMessageTags() {
        XCTAssertEqual(SearchOperators.macSupportedTypes.count, SearchOperatorType.allCases.count - 3)
        for type in [SearchOperatorType.contact, .geo, .mention] {
            XCTAssertFalse(SearchOperators.macSupportedTypes.contains(type))
            let parsed = SearchOperators.parse("type:\(type.rawValue) x", supportedTypes: SearchOperators.macSupportedTypes)
            XCTAssertNil(parsed.type)
            XCTAssertEqual(parsed.text, "type:\(type.rawValue) x")
        }
        XCTAssertEqual(SearchOperators.parse("type:photo x", supportedTypes: SearchOperators.macSupportedTypes).type, .photo)
    }

    func testStandardListMatchesTheSharedDataFile() throws {
        let contents = String(decoding: try self.sharedData("link-tracking-params.txt"), as: UTF8.self)
        let file = TrackingParameterList(fileContents: contents)
        XCTAssertEqual(file.ruleCount, TrackingParameterList.standard.ruleCount)
        for sample in [("utm_x", "a.com"), ("ysclid", "a.com"), ("spm", "a.com"), ("si", "youtu.be"), ("si", "a.com"), ("pd_rd_w", "www.amazon.com"), ("__cft__[0]", "facebook.com"), ("share_id", "tiktok.com"), ("feature", "open.spotify.com"), ("s", "x.com"), ("id", "a.com")] {
            XCTAssertEqual(file.isTracking(name: sample.0, host: sample.1), TrackingParameterList.standard.isTracking(name: sample.0, host: sample.1), "\(sample)")
        }
    }

    func testSharedLinkHygieneVectors() throws {
        let json = try JSONSerialization.jsonObject(with: self.sharedData("link-hygiene-vectors.json")) as! [String: Any]
        let strip = json["strip"] as! [[String: String]]
        XCTAssertFalse(strip.isEmpty)
        for vector in strip {
            XCTAssertEqual(LinkHygiene.strippingTracking(vector["input"]!), vector["output"]!, vector["input"]!)
        }
        let telegram = json["telegram"] as! [[String: Any]]
        XCTAssertFalse(telegram.isEmpty)
        for vector in telegram {
            XCTAssertEqual(LinkHygiene.isTelegramLink(vector["input"] as! String), vector["telegram"] as! Bool, vector["input"] as! String)
        }
    }

    func testSharedSearchOperatorVectors() throws {
        let json = try JSONSerialization.jsonObject(with: self.sharedData("search-operator-vectors.json")) as! [String: Any]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let now = formatter.date(from: json["now"] as! String)!
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let seconds: (Any?) -> Int32? = { value in
            guard let text = value as? String, let date = formatter.date(from: text) else {
                return nil
            }
            return Int32(date.timeIntervalSince1970)
        }
        let vectors = json["vectors"] as! [[String: Any]]
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let input = vector["input"] as! String
            let parsed = SearchOperators.parse(input, now: now, calendar: calendar, supportedTypes: SearchOperators.macSupportedTypes)
            XCTAssertEqual(parsed.text, vector["text"] as? String, input)
            XCTAssertEqual(parsed.fromName, vector["from"] as? String, input)
            XCTAssertEqual(parsed.minDate, seconds(vector["min"]), input)
            XCTAssertEqual(parsed.maxDate, seconds(vector["max"]), input)
            XCTAssertEqual(parsed.type?.rawValue, vector["type"] as? String, input)
        }
    }
}
