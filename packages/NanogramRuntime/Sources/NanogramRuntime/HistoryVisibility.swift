import AppKit

public enum HistoryVisibilityGate {
    public static func shouldApply(visible: Bool, isPlainGenericUpdate: Bool, hasScrollPosition: Bool, appliedOnce: Bool) -> Bool {
        if visible || !appliedOnce {
            return true
        }
        return !isPlainGenericUpdate || hasScrollPosition
    }
}

public final class WindowVisibilityObserver {
    private let notificationCenter: NotificationCenter
    private let appIsHidden: () -> Bool
    private let onChange: (Bool) -> Void
    private var observers: [NSObjectProtocol] = []

    public private(set) var isVisible: Bool = true

    public weak var window: NSWindow? {
        didSet {
            if self.window !== oldValue {
                self.update()
            }
        }
    }

    public init(notificationCenter: NotificationCenter = .default, appIsHidden: @escaping () -> Bool = { NSApp?.isHidden ?? false }, onChange: @escaping (Bool) -> Void) {
        self.notificationCenter = notificationCenter
        self.appIsHidden = appIsHidden
        self.onChange = onChange
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification
        ]
        for name in names {
            self.observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: nil, using: { [weak self] notification in
                guard let self = self else {
                    return
                }
                if let window = notification.object as? NSWindow, window !== self.window {
                    return
                }
                if Thread.isMainThread {
                    self.update()
                } else {
                    DispatchQueue.main.async {
                        self.update()
                    }
                }
            }))
        }
    }

    deinit {
        for observer in self.observers {
            self.notificationCenter.removeObserver(observer)
        }
    }

    public static func isVisible(window: NSWindow?, appIsHidden: Bool) -> Bool {
        guard let window = window else {
            return true
        }
        if appIsHidden || window.isMiniaturized || !window.isVisible {
            return false
        }
        return window.occlusionState.contains(.visible)
    }

    public func update() {
        let visible = WindowVisibilityObserver.isVisible(window: self.window, appIsHidden: self.appIsHidden())
        if visible != self.isVisible {
            self.isVisible = visible
            self.onChange(visible)
        }
    }
}
