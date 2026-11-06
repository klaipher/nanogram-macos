import XCTest
@testable import NanogramRuntime

final class LiveObjectDiagnosticsTests: XCTestCase {
    func testOffInReleaseUnlessTheKeyIsSet() {
        XCTAssertFalse(LiveObjectDiagnosticsPolicy.isEnabled(isDebugBuild: false, defaultsValue: false))
        XCTAssertTrue(LiveObjectDiagnosticsPolicy.isEnabled(isDebugBuild: false, defaultsValue: true))
        XCTAssertTrue(LiveObjectDiagnosticsPolicy.isEnabled(isDebugBuild: true, defaultsValue: false))
    }

    func testLineHasEveryCounter() {
        let line = LiveObjectDiagnosticsPolicy.format(trackingAreas: 5, trackedViews: 4, views: 900, observerObjects: 7, observerRegistrations: 31, blockObservers: 3)
        XCTAssertEqual(line, "trackingAreas=5 trackedViews=4 views=900 observerObjects=7 observerRegistrations=31 blockObservers=3")
    }

    func testRegistrationsAreCountedPerObjectAndRemovedTogether() {
        let registry = LiveObserverRegistry()
        let first = NSObject()
        let second = NSObject()
        registry.addObject(first)
        registry.addObject(first)
        registry.addObject(second)
        XCTAssertEqual(registry.snapshot.objects, 2)
        XCTAssertEqual(registry.snapshot.registrations, 3)
        registry.removeObject(first)
        XCTAssertEqual(registry.snapshot.objects, 1)
        XCTAssertEqual(registry.snapshot.registrations, 1)
    }

    func testRemovingOneRegistrationKeepsTheRest() {
        let registry = LiveObserverRegistry()
        let observer = NSObject()
        registry.addObject(observer)
        registry.addObject(observer)
        registry.removeOneRegistration(of: observer)
        XCTAssertEqual(registry.snapshot.registrations, 1)
        registry.removeOneRegistration(of: observer)
        XCTAssertEqual(registry.snapshot.objects, 0)
        registry.removeOneRegistration(of: observer)
        XCTAssertEqual(registry.snapshot.objects, 0)
    }

    func testBlockTokensAreLiveUntilRemoved() {
        let registry = LiveObserverRegistry()
        let token = NSObject()
        registry.addBlockToken(token)
        XCTAssertEqual(registry.snapshot.blocks, 1)
        registry.removeBlockToken(token)
        XCTAssertEqual(registry.snapshot.blocks, 0)
    }
}
