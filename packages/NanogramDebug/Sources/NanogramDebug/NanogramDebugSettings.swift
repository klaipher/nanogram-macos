import Foundation

public struct NanogramDebugChoice: Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct NanogramDebugOption: Equatable {
    public enum Kind: Equatable {
        case toggle(defaultValue: Bool)
        case choice(options: [NanogramDebugChoice], defaultValue: String)
    }

    public let id: String
    public let section: String
    public let title: String
    public let detail: String?
    public let requiresRelaunch: Bool
    public let kind: Kind

    public init(id: String, section: String, title: String, detail: String? = nil, requiresRelaunch: Bool = false, kind: Kind) {
        self.id = id
        self.section = section
        self.title = title
        self.detail = detail
        self.requiresRelaunch = requiresRelaunch
        self.kind = kind
    }

    public static func toggle(id: String, section: String, title: String, detail: String? = nil, requiresRelaunch: Bool = false, defaultValue: Bool) -> NanogramDebugOption {
        return NanogramDebugOption(id: id, section: section, title: title, detail: detail, requiresRelaunch: requiresRelaunch, kind: .toggle(defaultValue: defaultValue))
    }

    public static func choice(id: String, section: String, title: String, detail: String? = nil, requiresRelaunch: Bool = false, options: [NanogramDebugChoice], defaultValue: String) -> NanogramDebugOption {
        return NanogramDebugOption(id: id, section: section, title: title, detail: detail, requiresRelaunch: requiresRelaunch, kind: .choice(options: options, defaultValue: defaultValue))
    }
}

public struct NanogramDebugSection: Equatable {
    public let title: String
    public let options: [NanogramDebugOption]
}

public final class NanogramDebugObservation {
    private var cancelImpl: (() -> Void)?

    init(_ cancel: @escaping () -> Void) {
        self.cancelImpl = cancel
    }

    public func cancel() {
        let cancel = self.cancelImpl
        self.cancelImpl = nil
        cancel?()
    }

    deinit {
        self.cancel()
    }
}

public final class NanogramDebugSettings {
    public static let shared = NanogramDebugSettings(defaults: .standard)
    public static let didChangeNotification = Notification.Name("NanogramDebugSettingsDidChange")
    public static let optionIdKey = "id"

    private let defaults: UserDefaults
    private let keyPrefix: String
    private let lock = NSLock()
    private var registered: [NanogramDebugOption] = []
    private var observers: [Int: (id: String?, handler: (NanogramDebugSettings) -> Void)] = [:]
    private var nextObserverId = 0

    public init(defaults: UserDefaults, keyPrefix: String = "nanogram.debug.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func storageKey(_ id: String) -> String {
        return self.keyPrefix + id
    }

    public func register(_ option: NanogramDebugOption) {
        self.lock.lock()
        if let index = self.registered.firstIndex(where: { $0.id == option.id }) {
            self.registered[index] = option
        } else {
            self.registered.append(option)
        }
        self.lock.unlock()
    }

    public var options: [NanogramDebugOption] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.registered
    }

    public var sections: [NanogramDebugSection] {
        var order: [String] = []
        var grouped: [String: [NanogramDebugOption]] = [:]
        for option in self.options {
            if grouped[option.section] == nil {
                order.append(option.section)
            }
            grouped[option.section, default: []].append(option)
        }
        return order.map { NanogramDebugSection(title: $0, options: grouped[$0] ?? []) }
    }

    public func option(_ id: String) -> NanogramDebugOption? {
        return self.options.first(where: { $0.id == id })
    }

    public func bool(_ id: String) -> Bool {
        if let value = self.defaults.object(forKey: self.storageKey(id)) as? Bool {
            return value
        }
        if case let .toggle(defaultValue)? = self.option(id)?.kind {
            return defaultValue
        }
        return false
    }

    public func choice(_ id: String) -> String? {
        guard let option = self.option(id), case let .choice(options, defaultValue) = option.kind else {
            return self.defaults.string(forKey: self.storageKey(id))
        }
        if let stored = self.defaults.string(forKey: self.storageKey(id)), options.contains(where: { $0.id == stored }) {
            return stored
        }
        return defaultValue
    }

    public func isOverridden(_ id: String) -> Bool {
        return self.defaults.object(forKey: self.storageKey(id)) != nil
    }

    public func set(_ id: String, bool value: Bool) {
        if self.isOverridden(id), self.bool(id) == value {
            return
        }
        self.defaults.set(value, forKey: self.storageKey(id))
        self.notify(id)
    }

    public func set(_ id: String, choice value: String) {
        if self.isOverridden(id), self.choice(id) == value {
            return
        }
        self.defaults.set(value, forKey: self.storageKey(id))
        self.notify(id)
    }

    public func reset(_ id: String) {
        guard self.isOverridden(id) else {
            return
        }
        self.defaults.removeObject(forKey: self.storageKey(id))
        self.notify(id)
    }

    public func resetAll() {
        for option in self.options {
            self.reset(option.id)
        }
    }

    public func observe(_ id: String? = nil, _ handler: @escaping (NanogramDebugSettings) -> Void) -> NanogramDebugObservation {
        self.lock.lock()
        let observerId = self.nextObserverId
        self.nextObserverId += 1
        self.observers[observerId] = (id, handler)
        self.lock.unlock()
        return NanogramDebugObservation { [weak self] in
            guard let self = self else {
                return
            }
            self.lock.lock()
            self.observers.removeValue(forKey: observerId)
            self.lock.unlock()
        }
    }

    private func notify(_ id: String) {
        self.lock.lock()
        let handlers = self.observers.values.filter { $0.id == nil || $0.id == id }.map { $0.handler }
        self.lock.unlock()
        for handler in handlers {
            handler(self)
        }
        NotificationCenter.default.post(name: NanogramDebugSettings.didChangeNotification, object: self, userInfo: [NanogramDebugSettings.optionIdKey: id])
    }
}
