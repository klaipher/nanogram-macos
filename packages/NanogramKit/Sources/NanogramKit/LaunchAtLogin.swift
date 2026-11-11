import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

public enum LaunchAtLoginAction: Equatable, Sendable {
    case register
    case unregister
    case none
}

public func launchAtLoginAction(storedPreference: Bool?, defaultApplied: Bool, status: LaunchAtLoginStatus) -> LaunchAtLoginAction {
    guard !defaultApplied, storedPreference != false else {
        return .none
    }
    switch status {
    case .notRegistered:
        return .register
    case .enabled, .requiresApproval, .notFound:
        return .none
    }
}

public struct LaunchAtLoginRowState: Equatable, Sendable {
    public let isOn: Bool
    public let needsApproval: Bool
}

public func launchAtLoginRowState(status: LaunchAtLoginStatus) -> LaunchAtLoginRowState {
    switch status {
    case .enabled:
        return LaunchAtLoginRowState(isOn: true, needsApproval: false)
    case .requiresApproval:
        return LaunchAtLoginRowState(isOn: true, needsApproval: true)
    case .notRegistered, .notFound:
        return LaunchAtLoginRowState(isOn: false, needsApproval: false)
    }
}

public struct LaunchAtLoginPreferences: @unchecked Sendable {
    public static let preferenceKey = "nanogram.launchAtLogin.enabled"
    public static let defaultAppliedKey = "nanogram.launchAtLogin.defaultApplied"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var storedPreference: Bool? {
        return defaults.object(forKey: Self.preferenceKey) as? Bool
    }

    public var defaultApplied: Bool {
        return defaults.bool(forKey: Self.defaultAppliedKey)
    }

    public func setStoredPreference(_ value: Bool) {
        defaults.set(value, forKey: Self.preferenceKey)
    }

    public func markDefaultApplied() {
        defaults.set(true, forKey: Self.defaultAppliedKey)
    }
}

public enum LaunchAtLogin {
    public static var status: LaunchAtLoginStatus {
        return map(SMAppService.mainApp.status)
    }

    static func map(_ status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        case .notRegistered:
            return .notRegistered
        @unknown default:
            return .notRegistered
        }
    }

    public static func applyDefault(preferences: LaunchAtLoginPreferences = LaunchAtLoginPreferences()) {
        let current = status
        let action = launchAtLoginAction(storedPreference: preferences.storedPreference, defaultApplied: preferences.defaultApplied, status: current)
        switch action {
        case .register:
            do {
                try SMAppService.mainApp.register()
            } catch {
                return
            }
        case .unregister:
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                return
            }
        case .none:
            break
        }
        if !preferences.defaultApplied {
            preferences.markDefaultApplied()
        }
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool, preferences: LaunchAtLoginPreferences = LaunchAtLoginPreferences()) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return false
        }
        preferences.setStoredPreference(enabled)
        preferences.markDefaultApplied()
        return true
    }
}
