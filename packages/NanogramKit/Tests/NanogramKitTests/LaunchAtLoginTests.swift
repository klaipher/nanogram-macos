import XCTest
@testable import NanogramKit

final class LaunchAtLoginTests: XCTestCase {
    func testFirstLaunchRegisters() {
        XCTAssertEqual(launchAtLoginAction(storedPreference: nil, defaultApplied: false, status: .notRegistered), .register)
    }

    func testFirstLaunchDoesNothingWhenAlreadyEnabled() {
        XCTAssertEqual(launchAtLoginAction(storedPreference: nil, defaultApplied: false, status: .enabled), .none)
        XCTAssertEqual(launchAtLoginAction(storedPreference: nil, defaultApplied: false, status: .requiresApproval), .none)
    }

    func testUserOffStaysOff() {
        XCTAssertEqual(launchAtLoginAction(storedPreference: false, defaultApplied: false, status: .notRegistered), .none)
        XCTAssertEqual(launchAtLoginAction(storedPreference: false, defaultApplied: true, status: .notRegistered), .none)
    }

    func testDisabledInSystemSettingsIsNotOverridden() {
        XCTAssertEqual(launchAtLoginAction(storedPreference: true, defaultApplied: true, status: .notRegistered), .none)
        XCTAssertEqual(launchAtLoginAction(storedPreference: nil, defaultApplied: true, status: .notRegistered), .none)
    }

    func testNeverRegistersOrUnregistersAfterDefaultApplied() {
        let statuses: [LaunchAtLoginStatus] = [.notRegistered, .enabled, .requiresApproval, .notFound]
        for status in statuses {
            for stored in [nil, true, false] as [Bool?] {
                XCTAssertEqual(launchAtLoginAction(storedPreference: stored, defaultApplied: true, status: status), .none)
            }
        }
    }

    func testRequiresApprovalShowsOnWithApprovalHint() {
        XCTAssertEqual(launchAtLoginRowState(status: .requiresApproval), LaunchAtLoginRowState(isOn: true, needsApproval: true))
    }

    func testRowStateForOtherStatuses() {
        XCTAssertEqual(launchAtLoginRowState(status: .enabled), LaunchAtLoginRowState(isOn: true, needsApproval: false))
        XCTAssertEqual(launchAtLoginRowState(status: .notRegistered), LaunchAtLoginRowState(isOn: false, needsApproval: false))
        XCTAssertEqual(launchAtLoginRowState(status: .notFound), LaunchAtLoginRowState(isOn: false, needsApproval: false))
    }

    func testPreferencesRoundTripAndDefaultFlag() throws {
        let suite = "LaunchAtLoginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LaunchAtLoginPreferences(defaults: defaults)
        XCTAssertNil(preferences.storedPreference)
        XCTAssertFalse(preferences.defaultApplied)
        preferences.setStoredPreference(false)
        preferences.markDefaultApplied()
        XCTAssertEqual(preferences.storedPreference, false)
        XCTAssertTrue(preferences.defaultApplied)
    }
}
