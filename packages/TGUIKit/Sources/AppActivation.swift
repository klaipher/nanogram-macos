import AppKit

/// Brings the app to the front. The one place that picks `NSApp.activate()` (macOS 14+) or
/// `activate(ignoringOtherApps:)`, so call sites in nonisolated closures no longer each warn about
/// main-actor isolation. Call it from the main thread; from another thread it hops to main first.
public func activateApp() {
    if Thread.isMainThread {
        MainActor.assumeIsolated { performActivateApp() }
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { performActivateApp() }
        }
    }
}

@MainActor
private func performActivateApp() {
    if #available(macOS 14.0, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
}
