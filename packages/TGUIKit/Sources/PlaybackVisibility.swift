import AppKit

public enum PlaybackVisibility {
    public static let didChangeNotification = Notification.Name("TGUIKitPlaybackVisibilityDidChange")

    private static let lock = NSLock()
    private static var screenAvailable = true

    public static var isScreenAvailable: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return screenAvailable
    }

    public static func setScreenAvailable(_ value: Bool) {
        lock.lock()
        let changed = screenAvailable != value
        screenAvailable = value
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    public static func addObserver(_ observer: Any, selector: Selector, window: NSWindow) {
        let center = NotificationCenter.default
        center.addObserver(observer, selector: selector, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.addObserver(observer, selector: selector, name: NSApplication.didHideNotification, object: nil)
        center.addObserver(observer, selector: selector, name: NSApplication.didUnhideNotification, object: nil)
        center.addObserver(observer, selector: selector, name: didChangeNotification, object: nil)
    }

    public static func isVisible(isKeyWindow: Bool, isWindowVisible: Bool, isAppHidden: Bool, isScreenAvailable: Bool) -> Bool {
        return isKeyWindow && isWindowVisible && !isAppHidden && isScreenAvailable
    }
}

public extension NSView {
    var isPlaybackVisible: Bool {
        return self.isPlaybackVisible(ignoringKeyWindow: false)
    }

    func isPlaybackVisible(ignoringKeyWindow: Bool) -> Bool {
        guard let window = self.window else {
            return false
        }
        return PlaybackVisibility.isVisible(isKeyWindow: window.isKeyWindow || ignoringKeyWindow, isWindowVisible: window.occlusionState.contains(.visible), isAppHidden: NSApp?.isHidden ?? false, isScreenAvailable: PlaybackVisibility.isScreenAvailable)
    }
}
