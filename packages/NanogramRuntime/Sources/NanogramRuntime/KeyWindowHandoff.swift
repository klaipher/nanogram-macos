import AppKit

@MainActor
public protocol KeyWindowHandoffCandidate: AnyObject {
    var isVisible: Bool { get }
    var isMiniaturized: Bool { get }
    var canBecomeKey: Bool { get }
}

extension NSWindow: KeyWindowHandoffCandidate {}

@MainActor
public enum KeyWindowHandoff {
    public static func windowToRestore<Window: KeyWindowHandoffCandidate>(previous: Window?, fallback: Window?, overlay: Window) -> Window? {
        for candidate in [previous, fallback] {
            guard let candidate, candidate !== overlay else {
                continue
            }
            if candidate.isVisible && !candidate.isMiniaturized && candidate.canBecomeKey {
                return candidate
            }
        }
        return nil
    }

    public static func restore<Window: KeyWindowHandoffCandidate>(previous: Window?, fallback: Window?, overlay: Window, makeKey: (Window) -> Void) {
        if let window = windowToRestore(previous: previous, fallback: fallback, overlay: overlay) {
            makeKey(window)
        }
    }
}
