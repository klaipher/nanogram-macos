import Cocoa

public enum SecondaryGlassGrouping {
    public static let defaultsKey = "NanogramGlassGroupSecondaryScreens"

    public static var isEnabled: Bool {
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }

    public static func containerSpacing(minimumGap: CGFloat, limit: CGFloat = 5) -> CGFloat {
        guard !minimumGap.isNaN else {
            return 0
        }
        return max(0, min(limit, minimumGap - 1))
    }
}

public final class SecondaryGlassGroup {
    public let container: GlassContainerView

    private init(container: GlassContainerView) {
        self.container = container
    }

    public static func make(isEnabled: Bool = SecondaryGlassGrouping.isEnabled, host: NSView, glasses: [LiquidGlassView], minimumGap: CGFloat, flipped: Bool) -> SecondaryGlassGroup? {
        guard isEnabled else {
            return nil
        }
        let spacing = SecondaryGlassGrouping.containerSpacing(minimumGap: minimumGap)
        let container = GlassContainerView(frame: host.bounds, flipped: flipped, spacing: spacing)
        host.addSubview(container, positioned: .below, relativeTo: host.subviews.first)
        let group = SecondaryGlassGroup(container: container)
        for glass in glasses {
            glass.removeFromSuperview()
            container.addGhost(glass)
        }
        return group
    }

    public func place(_ glass: LiquidGlassView, frame: NSRect, transition: ContainedViewLayoutTransition = .immediate) {
        container.setGhostFrame(glass, frame: frame, transition: transition)
    }

    public func updateLayout(size: NSSize, transition: ContainedViewLayoutTransition = .immediate) {
        container.updateLayout(size: size, transition: transition)
    }
}
