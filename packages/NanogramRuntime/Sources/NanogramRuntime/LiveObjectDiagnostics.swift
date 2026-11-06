import Foundation
import AppKit
import os

public enum LiveObjectDiagnosticsPolicy {
    public static let defaultsKey = "nanogram.liveObjectCounters"
    public static let interval: TimeInterval = 10.0

    public static func isEnabled(isDebugBuild: Bool, defaultsValue: Bool) -> Bool {
        return isDebugBuild || defaultsValue
    }

    public static func format(trackingAreas: Int, trackedViews: Int, views: Int, observerObjects: Int, observerRegistrations: Int, blockObservers: Int) -> String {
        return "trackingAreas=\(trackingAreas) trackedViews=\(trackedViews) views=\(views) observerObjects=\(observerObjects) observerRegistrations=\(observerRegistrations) blockObservers=\(blockObservers)"
    }
}

public final class LiveObserverRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let objects = NSMapTable<AnyObject, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let blockTokens = NSHashTable<AnyObject>(options: .weakMemory)

    public init() {
    }

    public func addObject(_ observer: AnyObject) {
        self.lock.lock()
        let current = self.objects.object(forKey: observer)?.intValue ?? 0
        self.objects.setObject(NSNumber(value: current + 1), forKey: observer)
        self.lock.unlock()
    }

    public func removeObject(_ observer: AnyObject) {
        self.lock.lock()
        self.objects.removeObject(forKey: observer)
        self.lock.unlock()
    }

    public func removeOneRegistration(of observer: AnyObject) {
        self.lock.lock()
        if let current = self.objects.object(forKey: observer)?.intValue {
            if current <= 1 {
                self.objects.removeObject(forKey: observer)
            } else {
                self.objects.setObject(NSNumber(value: current - 1), forKey: observer)
            }
        }
        self.lock.unlock()
    }

    public func addBlockToken(_ token: AnyObject) {
        self.lock.lock()
        self.blockTokens.add(token)
        self.lock.unlock()
    }

    public func removeBlockToken(_ token: AnyObject) {
        self.lock.lock()
        self.blockTokens.remove(token)
        self.lock.unlock()
    }

    public var snapshot: (objects: Int, registrations: Int, blocks: Int) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        var registrations = 0
        var objects = 0
        let enumerator = self.objects.objectEnumerator()
        while let value = enumerator?.nextObject() as? NSNumber {
            registrations += value.intValue
            objects += 1
        }
        return (objects, registrations, self.blockTokens.count)
    }
}

public enum LiveObjectDiagnostics {
    private static let registry = LiveObserverRegistry()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "Telegram", category: "LiveObjectDiagnostics")

    public static func startIfEnabled() {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        guard LiveObjectDiagnosticsPolicy.isEnabled(isDebugBuild: isDebugBuild, defaultsValue: UserDefaults.standard.bool(forKey: LiveObjectDiagnosticsPolicy.defaultsKey)) else {
            return
        }
        LiveObjectDiagnostics.lock.lock()
        defer {
            LiveObjectDiagnostics.lock.unlock()
        }
        if LiveObjectDiagnostics.started {
            return
        }
        LiveObjectDiagnostics.started = true
        NotificationCenter.swizzleObserverCounting(LiveObjectDiagnostics.registry)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + LiveObjectDiagnosticsPolicy.interval, repeating: LiveObjectDiagnosticsPolicy.interval, leeway: .seconds(1))
        timer.setEventHandler {
            MainActor.assumeIsolated {
                LiveObjectDiagnostics.report()
            }
        }
        timer.resume()
        LiveObjectDiagnostics.timer = timer
    }

    @MainActor
    static func report() {
        var trackingAreas = 0
        var trackedViews = 0
        var views = 0
        for window in NSApp.windows {
            if let contentView = window.contentView {
                LiveObjectDiagnostics.count(contentView, trackingAreas: &trackingAreas, trackedViews: &trackedViews, views: &views)
            }
        }
        let observers = LiveObjectDiagnostics.registry.snapshot
        let line = LiveObjectDiagnosticsPolicy.format(trackingAreas: trackingAreas, trackedViews: trackedViews, views: views, observerObjects: observers.objects, observerRegistrations: observers.registrations, blockObservers: observers.blocks)
        os_log("%{public}@", log: LiveObjectDiagnostics.log, type: .info, line)
    }

    @MainActor
    private static func count(_ view: NSView, trackingAreas: inout Int, trackedViews: inout Int, views: inout Int) {
        views += 1
        let areas = view.trackingAreas.count
        if areas > 0 {
            trackingAreas += areas
            trackedViews += 1
        }
        for subview in view.subviews {
            LiveObjectDiagnostics.count(subview, trackingAreas: &trackingAreas, trackedViews: &trackedViews, views: &views)
        }
    }
}

nonisolated(unsafe) private var observerRegistryForSwizzling: LiveObserverRegistry?

extension NotificationCenter {
    fileprivate static func swizzleObserverCounting(_ registry: LiveObserverRegistry) {
        observerRegistryForSwizzling = registry
        let pairs: [(Selector, Selector)] = [
            (NSSelectorFromString("addObserver:selector:name:object:"), #selector(NotificationCenter.nanogramCountedAddObserver(_:selector:name:object:))),
            (NSSelectorFromString("addObserverForName:object:queue:usingBlock:"), #selector(NotificationCenter.nanogramCountedAddObserver(forName:object:queue:using:))),
            (NSSelectorFromString("removeObserver:"), #selector(NotificationCenter.nanogramCountedRemoveObserver(_:))),
            (NSSelectorFromString("removeObserver:name:object:"), #selector(NotificationCenter.nanogramCountedRemoveObserver(_:name:object:)))
        ]
        let cls: AnyClass = NotificationCenter.self
        for (original, replacement) in pairs {
            if let originalMethod = class_getInstanceMethod(cls, original), let replacementMethod = class_getInstanceMethod(cls, replacement) {
                method_exchangeImplementations(originalMethod, replacementMethod)
            }
        }
    }

    @objc dynamic fileprivate func nanogramCountedAddObserver(_ observer: Any, selector: Selector, name: NSNotification.Name?, object: Any?) {
        observerRegistryForSwizzling?.addObject(observer as AnyObject)
        self.nanogramCountedAddObserver(observer, selector: selector, name: name, object: object)
    }

    @objc dynamic fileprivate func nanogramCountedAddObserver(forName name: NSNotification.Name?, object: Any?, queue: OperationQueue?, using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        let token = self.nanogramCountedAddObserver(forName: name, object: object, queue: queue, using: block)
        observerRegistryForSwizzling?.addBlockToken(token)
        return token
    }

    @objc dynamic fileprivate func nanogramCountedRemoveObserver(_ observer: Any) {
        let object = observer as AnyObject
        observerRegistryForSwizzling?.removeObject(object)
        observerRegistryForSwizzling?.removeBlockToken(object)
        self.nanogramCountedRemoveObserver(observer)
    }

    @objc dynamic fileprivate func nanogramCountedRemoveObserver(_ observer: Any, name: NSNotification.Name?, object: Any?) {
        observerRegistryForSwizzling?.removeOneRegistration(of: observer as AnyObject)
        self.nanogramCountedRemoveObserver(observer, name: name, object: object)
    }
}
