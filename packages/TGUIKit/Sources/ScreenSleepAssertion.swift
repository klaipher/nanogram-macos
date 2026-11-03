import Foundation
import IOKit.pwr_mgt

public final class ScreenSleepAssertion {
    private let reason: String
    private let create: (String) -> IOPMAssertionID?
    private let release: (IOPMAssertionID) -> Void
    private var assertionID: IOPMAssertionID?

    public static func isNeeded(hasVisibleVideo: Bool, isWindowVisible: Bool) -> Bool {
        return hasVisibleVideo && isWindowVisible
    }

    public convenience init(reason: String) {
        self.init(reason: reason, create: { reason in
            var assertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertionID)
            return result == kIOReturnSuccess ? assertionID : nil
        }, release: { assertionID in
            IOPMAssertionRelease(assertionID)
        })
    }

    init(reason: String, create: @escaping (String) -> IOPMAssertionID?, release: @escaping (IOPMAssertionID) -> Void) {
        self.reason = reason
        self.create = create
        self.release = release
    }

    deinit {
        if let assertionID = self.assertionID {
            self.release(assertionID)
        }
    }

    public var isHeld: Bool {
        return self.assertionID != nil
    }

    public func update(needed: Bool) {
        if needed {
            _ = self.disableScreenSleep()
        } else {
            _ = self.enableScreenSleep()
        }
    }

    @discardableResult
    public func disableScreenSleep() -> Bool? {
        guard self.assertionID == nil else {
            return nil
        }
        self.assertionID = self.create(self.reason)
        return self.assertionID != nil
    }

    @discardableResult
    public func enableScreenSleep() -> Bool {
        guard let assertionID = self.assertionID else {
            return false
        }
        self.release(assertionID)
        self.assertionID = nil
        return true
    }
}
