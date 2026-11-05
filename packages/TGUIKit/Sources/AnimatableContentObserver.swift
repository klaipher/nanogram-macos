import AppKit

public struct AnimatableContentObserverOptions: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
    public static let contentBounds = AnimatableContentObserverOptions(rawValue: 1 << 0)
    public static let documentFrame = AnimatableContentObserverOptions(rawValue: 1 << 1)
    public static let ownFrame = AnimatableContentObserverOptions(rawValue: 1 << 2)
    public static let ownBounds = AnimatableContentObserverOptions(rawValue: 1 << 3)
}

final class AnimatableContentHub: @unchecked Sendable {
    static let shared = AnimatableContentHub()

    final class Subscription {
        fileprivate let key: SourceKey
        fileprivate let handler: (NSNotification) -> Void
        fileprivate init(key: SourceKey, handler: @escaping (NSNotification) -> Void) {
            self.key = key
            self.handler = handler
        }
    }

    fileprivate struct SourceKey: Hashable {
        let object: ObjectIdentifier?
        let name: Notification.Name
    }

    private final class Source {
        weak var object: AnyObject?
        var token: NSObjectProtocol?
        var listeners: [ObjectIdentifier: Subscription] = [:]
        var order: [ObjectIdentifier] = []
    }

    private let lock = NSLock()
    private var sources: [SourceKey: Source] = [:]

    var centerObserverCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sources.count
    }

    func subscribe(name: Notification.Name, object: AnyObject?, handler: @escaping (NSNotification) -> Void) -> Subscription {
        let key = SourceKey(object: object.map { ObjectIdentifier($0) }, name: name)
        let subscription = Subscription(key: key, handler: handler)
        var staleToken: NSObjectProtocol?
        lock.lock()
        defer {
            lock.unlock()
            if let staleToken {
                NotificationCenter.default.removeObserver(staleToken)
            }
        }
        var source = sources[key]
        if let existing = source, existing.object !== object {
            staleToken = existing.token
            source = nil
        }
        let target: Source
        if let source {
            target = source
        } else {
            target = Source()
            target.object = object
            target.token = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil, using: { [weak self] notification in
                self?.deliver(notification, key: key)
            })
            sources[key] = target
        }
        let id = ObjectIdentifier(subscription)
        target.listeners[id] = subscription
        target.order.append(id)
        return subscription
    }

    func unsubscribe(_ subscription: Subscription) {
        var staleToken: NSObjectProtocol?
        lock.lock()
        defer {
            lock.unlock()
            if let staleToken {
                NotificationCenter.default.removeObserver(staleToken)
            }
        }
        guard let source = sources[subscription.key] else {
            return
        }
        let id = ObjectIdentifier(subscription)
        guard source.listeners.removeValue(forKey: id) != nil else {
            return
        }
        source.order.removeAll(where: { $0 == id })
        if source.listeners.isEmpty {
            staleToken = source.token
            sources[subscription.key] = nil
        }
    }

    private func deliver(_ notification: Notification, key: SourceKey) {
        lock.lock()
        let listeners: [Subscription]
        if let source = sources[key] {
            listeners = source.order.compactMap { source.listeners[$0] }
        } else {
            listeners = []
        }
        lock.unlock()
        guard !listeners.isEmpty else {
            return
        }
        let bridged = notification as NSNotification
        for listener in listeners {
            listener.handler(bridged)
        }
    }
}

private final class AnimatableContentNotificationTarget: NSObject {
    weak var target: AnyObject?
    var selector: Selector?

    @objc func forwardNotification(_ notification: NSNotification) {
        guard let target, let selector else {
            return
        }
        _ = target.perform(selector, with: notification)
    }
}

public final class AnimatableContentObserver {
    private weak var observedWindow: NSWindow?
    private weak var observedContentView: NSView?
    private weak var observedDocumentView: NSView?
    private weak var observedView: NSView?
    private lazy var notificationTarget = AnimatableContentNotificationTarget()
    private var observedOptions: AnimatableContentObserverOptions = []
    private var registered = false
    private var subscriptions: [AnimatableContentHub.Subscription] = []

    public init() {
    }

    public func update(for view: NSView, target: AnyObject, selector: Selector, options: AnimatableContentObserverOptions = [.contentBounds, .documentFrame]) {
        guard view.window != nil else {
            unregister()
            return
        }
        let scrollView = view.enclosingScrollView
        self.update(for: view, target: target, selector: selector, contentView: scrollView?.contentView, documentView: scrollView?.documentView, options: options)
    }

    public func update(for view: NSView, target: AnyObject, selector: Selector, contentView: NSView?, documentView: NSView?, options: AnimatableContentObserverOptions) {
        guard let window = view.window else {
            unregister()
            return
        }
        if registered
            && observedWindow === window
            && observedContentView === contentView
            && observedDocumentView === documentView
            && observedView === view
            && notificationTarget.target === target
            && notificationTarget.selector == selector
            && observedOptions == options {
            return
        }
        unregister()
        notificationTarget.target = target
        notificationTarget.selector = selector

        let hub = AnimatableContentHub.shared
        let forwarder = notificationTarget
        func add(_ name: Notification.Name, _ object: AnyObject?) {
            subscriptions.append(hub.subscribe(name: name, object: object, handler: { [weak forwarder] notification in
                forwarder?.forwardNotification(notification)
            }))
        }
        add(NSWindow.didBecomeKeyNotification, window)
        add(NSWindow.didResignKeyNotification, window)
        add(NSWindow.didChangeOcclusionStateNotification, window)
        add(NSApplication.didHideNotification, nil)
        add(NSApplication.didUnhideNotification, nil)
        add(PlaybackVisibility.didChangeNotification, nil)
        if options.contains(.contentBounds), let contentView {
            add(NSView.boundsDidChangeNotification, contentView)
        }
        if options.contains(.ownBounds) {
            add(NSView.boundsDidChangeNotification, view)
        }
        if options.contains(.documentFrame), let documentView {
            add(NSView.frameDidChangeNotification, documentView)
        }
        if options.contains(.ownFrame) {
            add(NSView.frameDidChangeNotification, view)
        }
        if (options.contains(.contentBounds) && contentView == nil) || (options.contains(.documentFrame) && documentView == nil) {
            add(NSWindow.didResizeNotification, window)
        }
        observedWindow = window
        observedContentView = contentView
        observedDocumentView = documentView
        observedView = view
        observedOptions = options
        registered = true
    }

    private func unregister() {
        guard registered else {
            return
        }
        for subscription in subscriptions {
            AnimatableContentHub.shared.unsubscribe(subscription)
        }
        subscriptions.removeAll()
        notificationTarget.target = nil
        notificationTarget.selector = nil
        observedWindow = nil
        observedContentView = nil
        observedDocumentView = nil
        observedView = nil
        observedOptions = []
        registered = false
    }

    deinit {
        unregister()
    }
}

public final class AnimatableContentTokenObserver {
    private weak var observedWindow: NSWindow?
    private weak var observedContentView: NSView?
    private weak var observedDocumentView: NSView?
    private var tokens: [AnimatableContentHub.Subscription] = []
    private var handler: ((Notification) -> Void)?
    private var generation = 0

    public init() {
    }

    public func update(for view: NSView, handler: @escaping (Notification) -> Void) {
        guard let window = view.window else {
            removeObservers()
            return
        }
        let scrollView = view.enclosingScrollView
        let contentView = scrollView?.contentView
        let documentView = scrollView?.documentView
        if !tokens.isEmpty
            && observedWindow === window
            && observedContentView === contentView
            && observedDocumentView === documentView {
            self.handler = handler
            return
        }
        removeObservers()
        self.handler = handler
        let generation = self.generation
        let deliver: (Notification) -> Void = { [weak self] notification in
            guard let self, self.generation == generation else {
                return
            }
            self.handler?(notification)
        }
        let callback: (NSNotification) -> Void = { source in
            let notification = source as Notification
            if Thread.isMainThread {
                deliver(notification)
            } else {
                let delivery = MainThreadNotificationDelivery(deliver: deliver, notification: notification)
                DispatchQueue.main.async { delivery.run() }
            }
        }
        var observed: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didBecomeKeyNotification, window),
            (NSWindow.didResignKeyNotification, window),
            (NSWindow.didChangeOcclusionStateNotification, window),
            (NSApplication.didHideNotification, nil),
            (NSApplication.didUnhideNotification, nil),
            (PlaybackVisibility.didChangeNotification, nil)
        ]
        if let contentView {
            observed.append((NSView.boundsDidChangeNotification, contentView))
        }
        if let documentView {
            observed.append((NSView.frameDidChangeNotification, documentView))
        }
        if contentView == nil || documentView == nil {
            observed.append((NSWindow.didResizeNotification, window))
        }
        for (name, object) in observed {
            tokens.append(AnimatableContentHub.shared.subscribe(name: name, object: object, handler: callback))
        }
        observedWindow = window
        observedContentView = contentView
        observedDocumentView = documentView
    }

    public func removeObservers() {
        generation &+= 1
        for token in tokens {
            AnimatableContentHub.shared.unsubscribe(token)
        }
        tokens.removeAll()
        handler = nil
        observedWindow = nil
        observedContentView = nil
        observedDocumentView = nil
    }

    deinit {
        removeObservers()
    }
}

private struct MainThreadNotificationDelivery: @unchecked Sendable {
    let deliver: (Notification) -> Void
    let notification: Notification

    func run() {
        deliver(notification)
    }
}
