import Cocoa
import ColorPalette
import ObjcUtils

public enum LiquidGlassAppearance {
    case automatic
    case forceLight
    case forceDark
}

public extension NSAppearance {
    var glassAppearance: LiquidGlassAppearance {
        if #available(macOS 10.14, *) {
            if self.bestMatch(from: [.darkAqua, .vibrantDark]) != nil {
                return .forceDark
            }
        } else if self.name == .vibrantDark {
            return .forceDark
            // Fallback on earlier versions
        }
        return .forceLight
    }
}

@available(macOS 26.0, *)
public final class AdaptiveGlassEffectView: NSGlassEffectView {

    public var onAppearanceChange: ((NSAppearance) -> Void)? {
        didSet {
            onAppearanceChange?(self.effectiveAppearance)
        }
    }
    
    public override func menu(for event: NSEvent) -> NSMenu? {
        return nil
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?(self.effectiveAppearance)
    }

    private static let adaptiveSelector = Selector(("set_adaptiveAppearance:"))

#if compiler(>=6.4)
    // NSViewCornerConfiguration exists only in the macOS 27 SDK — @available can't help with a type
    // the SDK doesn't declare, so the whole override must compile out on older toolchains
    // (Xcode 26.x ships Swift 6.3).
    @available(macOS 27.0, *)
    public override var cornerConfiguration: NSViewCornerConfiguration? {
        return .capsule(maximumRadius: cornerRadius)
    }
#endif

    public func applyForcedAppearance(_ appearance: LiquidGlassAppearance) {
        guard self.responds(to: AdaptiveGlassEffectView.adaptiveSelector) else { return }
        let value: Int
        switch appearance {
        case .automatic:
            value = 0
        case .forceLight:
            value = 1
        case .forceDark:
            value = 2
        }
        typealias SetAdaptiveFunc = @convention(c) (NSObject, Selector, Int) -> Void
        let imp = self.method(for: AdaptiveGlassEffectView.adaptiveSelector)
        let function = unsafeBitCast(imp, to: SetAdaptiveFunc.self)
        function(self, AdaptiveGlassEffectView.adaptiveSelector, value)
    }
}

open class LiquidGlassView: View, GlassEnvironmentListener {

    public var cornerRadius: CGFloat {
        didSet {
            if oldValue != cornerRadius {
                applyCornerRadius()
            }
        }
    }

    public var hasShadow: Bool {
        didSet {
            if oldValue != hasShadow {
                applyShadow()
            }
        }
    }

    public var hasBorder: Bool {
        didSet {
            if oldValue != hasBorder {
                applyBorder()
            }
        }
    }

    public var tintAlpha: CGFloat {
        didSet {
            if oldValue != tintAlpha {
                applyAppearance(presentation)
            }
        }
    }

    public var customTint: NSColor? {
        didSet {
            let changed: Bool
            switch (oldValue, customTint) {
            case (nil, nil): changed = false
            case let (l?, r?): changed = !l.isEqual(r)
            default: changed = true
            }
            if !changed { return }
            applyAppearance(presentation)
        }
    }

    public let forceBlur: Bool

    public var glassGroup: GlassGroup? {
        didSet {
            if GlassDebug.isDisabled(oldValue) != GlassDebug.isDisabled(glassGroup) {
                glassEnvironmentDidChange()
            }
        }
    }

    private var groupDisabled: Bool {
        return GlassDebug.isDisabled(glassGroup)
    }

    private var accessibilityState: GlassAccessibilityState {
        return GlassAccessibilityMonitor.shared.state
    }

    private var usesGlass: Bool {
        return System.liquidGlass && !forceBlur && !accessibilityState.prefersOpaque && !groupDisabled
    }

    public func glassEnvironmentDidChange() {
        guard effectView != nil else {
            return
        }
        rebuildEffectView()
        applyAppearance(presentation)
        applyBorder()
        applyShadow()
    }

    public func setCustomTint(_ color: NSColor?, animated: Bool, duration: TimeInterval = 0.25) {
        // The fallback path no longer rebuilds the effect view when crossing
        // nil↔non-nil — the tint is composed via `tintOverlay`, which is
        // added/removed in place. So there's nothing async/rebuild-related
        // to gate; just write through to the property.
        customTint = color
    }

    public var forceAppearance: LiquidGlassAppearance {
        didSet {
            if oldValue != forceAppearance {
                // Apple's NSGlassEffectView captures its render appearance at
                // construction time — flipping `.appearance` afterwards leaves
                // the SDF compositor showing the previously-baked tint/luma.
                // Rebuilding with the new forced appearance is the only way
                // to re-render correctly when crossing dark↔light boundaries.
                rebuildEffectView()
                applyForceAppearance()
            }
        }
    }

    public var onAppearanceChange: ((NSAppearance) -> Void)? {
        didSet {
            if #available(macOS 26.0, *), let glass = effectView as? AdaptiveGlassEffectView {
                onAppearanceChange?(glass.effectiveAppearance)
            }
        }
    }

    public internal(set) var effectView: NSView!

    /// Solid-colour overlay layered on top of the fallback `NSVisualEffectView`
    /// when `customTint` is set. Replaces the older "either blur OR solid"
    /// branch in `rebuildEffectView`: the fallback path now always renders
    /// the system blur, and a tint colour is composed on top instead of
    /// replacing the blur entirely. Lifecycle is managed by
    /// `applyAppearance(_:)` — created on first non-nil tint, removed when
    /// tint goes back to nil.
    private var tintOverlay: View?

    /// Set the wrapper's frame and propagate the animation to every
    /// internal layer. Default (standalone) mode: `appearanceContainer` and
    /// `effectView` are subviews of self at .zero size-only origin. When
    /// hosted by a `GlassContainerView` the inner views are reparented as
    /// siblings of self and the container animates them itself with the
    /// FULL frame (parent coords) — so we only animate the inner views
    /// here when they are still our subviews.
    public func setAnimatorFrame(_ frame: NSRect) {
        updateCornerRadius(size: frame.size)
        let sizeChanged = validLayout != frame.size

        self.animator().frame = frame

        if sizeChanged, effectView.superview === self {
            let inner = NSRect(origin: .zero, size: frame.size)
            effectView.animator().frame = inner
        }
        validLayout = frame.size
    }
    public let appearanceContainer: GlassEffectAppearanceContainer
    private var followsTheme: Bool
    private var validLayout: NSSize?

    /// Last frame that `GlassContainerView.setGhostFrame(_:frame:transition:)`
    /// applied to this ghost (outer wrapper + appearanceContainer + effectView,
    /// all in glassContent coords). The container uses it to short-circuit
    /// redundant ghost-frame updates without comparing three separate view
    /// frames every layout pass. Reset to `nil` when the ghost is removed
    /// from / added to a container so the first call after re-parenting
    /// always re-applies.
    public internal(set) var validGhostFrame: NSRect?

    public init(frame: NSRect, cornerRadius: CGFloat = 16, hasShadow: Bool = true, hasBorder: Bool = true, tintAlpha: CGFloat = 0.3, forceAppearance: LiquidGlassAppearance? = nil, customTint: NSColor? = nil, forceBlur: Bool = false) {
        self.cornerRadius = cornerRadius
        self.hasShadow = hasShadow
        self.hasBorder = hasBorder
        self.tintAlpha = tintAlpha
        self.customTint = customTint
        self.forceBlur = forceBlur
        self.followsTheme = (forceAppearance == nil)
        self.forceAppearance = forceAppearance ?? presentation.appearance.glassAppearance
        appearanceContainer = GlassEffectAppearanceContainer(frame: frame.size.bounds)
        appearanceContainer.wantsLayer = true
        appearanceContainer.layer?.masksToBounds = false

        super.init(frame: frame)

        wantsLayer = true
        layer?.masksToBounds = false
        backgroundColor = .clear

        GlassAccessibilityMonitor.shared.register(self)
        rebuildEffectView()

        applyForceAppearance()
        applyAppearance(presentation)
        applyShadow()
        applyBorder()
    }

    private var rebuildState: LiquidGlassRebuildKey?
    private var appliedTint = AppliedValueCache<NSColor>()
    private var appliedEffectAppearance = AppliedValueCache<NSAppearance>()
    private var appliedBorder = AppliedValueCache<LiquidGlassBorderKey>()
    private var appliedCornerRadius = AppliedValueCache<CGFloat>()

    private func currentRebuildState() -> LiquidGlassRebuildKey {
        return LiquidGlassRebuildKey(
            usesGlass: usesGlass,
            blurEnabled: System.blurEnabled && !groupDisabled,
            forceAppearance: forceAppearance
        )
    }

    private func rebuildEffectView() {
        let newState = currentRebuildState()
        if let cached = rebuildState, cached == newState, effectView != nil {
            // Same effect type and same appearance baking — nothing to do.
            // Downstream (`applyAppearance` etc.) refreshes tint/colors
            // without needing to recreate the view.
            return
        }
        rebuildState = newState

        // Capture the old effectView's parent + frame + z-order BEFORE we
        // tear it down. This may be:
        //   - `appearanceContainer` (default standalone hierarchy), or
        //   - some other view (e.g. `glassContent` of a GlassContainerView,
        //     which calls addGhost(_:) and reparents effectView as a sibling
        //     of the wrapper). Restoring into the same superview at the same
        //     frame keeps the SDF compositor's window-coord tracking stable
        //     across rebuilds and works for either hosting strategy.
        let previousSuperview = effectView?.superview
        let previousFrame = effectView?.frame
        let previousAboveSibling: NSView? = {
            guard let parent = previousSuperview, let current = effectView else { return nil }
            guard let idx = parent.subviews.firstIndex(of: current), idx > 0 else { return nil }
            return parent.subviews[idx - 1]
        }()

        effectView?.removeFromSuperview()
        effectView = nil
        appliedCornerRadius.invalidate()
        appliedTint.invalidate()
        appliedEffectAppearance.invalidate()
        appliedBorder.invalidate()

        if newState.usesGlass {
            if #available(macOS 26.0, *) {
                let glass = AdaptiveGlassEffectView()
                glass.wantsLayer = true
                glass.cornerRadius = cornerRadius
                glass.onAppearanceChange = { [weak self] appearance in
                    self?.onAppearanceChange?(appearance)
                }
                self.effectView = glass
                applyForceAppearance()
            }
        }
        if effectView == nil {
            if newState.blurEnabled {
                let visual = NSVisualEffectView()
                visual.wantsLayer = true
                visual.layerContentsRedrawPolicy = .onSetNeedsDisplay
                visual.layer?.masksToBounds = true
                visual.blendingMode = .withinWindow
                visual.state = .active
                self.effectView = visual
            } else {
                // Both glass and blur are disabled (lite mode). Drop down to a
                // plain solid-coloured view using `theme.colors.background` so
                // the surface is still readable but costs nothing to render.
                // `tintOverlay` keeps composing customTint on top exactly as
                // it does for the blur path.
                let solid = View()
                solid.wantsLayer = true
                solid.backgroundColor = presentation.colors.background
                self.effectView = solid
            }
        }

        let target = previousSuperview ?? self
        if let above = previousAboveSibling {
            target.addSubview(effectView, positioned: .above, relativeTo: above)
        } else if target === self {
            target.addSubview(effectView, positioned: .below, relativeTo: nil)
        } else {
            target.addSubview(effectView)
        }
        if let previousFrame {
            effectView.frame = previousFrame
        }


        // Reset cached layout so updateLayout actually applies frame/cornerRadius
        validLayout = nil
        applyBorder()
        // The shadow lives on `effectView`, which was just (re)built; re-apply
        // so the new instance picks up the configured shadow.
        applyShadow()
        if let size = bounds.size as NSSize?, size != .zero {
            updateLayout(size: size, transition: .immediate)
        }
    }

    private func applyForceAppearance() {
        if #available(macOS 26.0, *), let glass = effectView as? AdaptiveGlassEffectView {
            glass.applyForcedAppearance(forceAppearance)
        }
        // Trigger a re-render
        effectView.needsDisplay = true
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public required init(frame frameRect: NSRect) {
        fatalError("init(frame:) has not been implemented")
    }

    open override func updateLocalizationAndTheme(theme: PresentationTheme) {
        super.updateLocalizationAndTheme(theme: theme)
        rebuildEffectView()
        applyAppearance(theme)
        applyBorder()
    }

    private func applyEffectAppearance(_ appearance: NSAppearance) {
        guard appliedEffectAppearance.needsWrite(appearance) else {
            return
        }
        effectView.appearance = appearance
    }

    private func applyAppearance(_ theme: PresentationTheme) {
        let palette: ColorPalette
        if followsTheme {
            palette = theme.colors
            applyEffectAppearance(theme.appearance)
            forceAppearance = theme.appearance.glassAppearance
        } else {
            switch forceAppearance {
            case .forceDark:
                if #available(macOS 10.14, *) {
                    applyEffectAppearance(NSAppearance(named: .darkAqua) ?? theme.appearance)
                } else {
                    applyEffectAppearance(NSAppearance(named: .vibrantDark) ?? theme.appearance)
                }
                palette = darkPalette
            case .forceLight:
                palette = whitePalette
                applyEffectAppearance(NSAppearance(named: .aqua) ?? theme.appearance)
            case .automatic:
                palette = theme.colors
                applyEffectAppearance(theme.appearance)
            }
        }
        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            let tint = customTint ?? palette.background.withAlphaComponent(tintAlpha)
            if appliedTint.needsWrite(tint) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                glass.tintColor = tint
                CATransaction.commit()
            }
        } else if let visual = effectView as? NSVisualEffectView {
            if #available(macOS 10.14, *) {
                let isDark = (visual.appearance ?? visual.effectiveAppearance).glassAppearance == .forceDark
                visual.material = isDark ? .hudWindow : .titlebar
            } else {
                visual.material = .appearanceBased
            }
            applyTintOverlay(host: visual)
        } else if let solid = effectView {
            solid.layer?.backgroundColor = palette.background.cgColor
            applyTintOverlay(host: solid)
        }
    }

    /// Compose a solid-coloured overlay on top of the fallback blur surface
    /// so a `customTint` shows through without losing the blur. Hosted as a
    /// subview of the `NSVisualEffectView` so it tracks the same coord space
    /// as the blur it sits on. Created lazily and torn down via
    /// `performSubviewRemoval` so callers that animate tint changes get a
    /// fade-out instead of a snap.
    private func applyTintOverlay(host: NSView) {
        guard let tint = customTint else {
            if let overlay = tintOverlay {
                performSubviewRemoval(overlay, animated: false)
                tintOverlay = nil
            }
            return
        }
        let overlay: View
        if let view = tintOverlay, view.superview === host {
            overlay = view
        } else {
            tintOverlay?.removeFromSuperview()
            overlay = View()
            overlay.userInteractionEnabled = false
            overlay.isEventLess = true
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = host.bounds
            overlay.layer?.cornerRadius = cornerRadius
            overlay.layer?.masksToBounds = true
            host.addSubview(overlay)
            tintOverlay = overlay
            appliedCornerRadius.invalidate()
        }
        overlay.layer?.backgroundColor = tint.cgColor
    }

    private func applyCornerRadius() {
        writeCornerRadius(cornerRadius)
        applyBorder()
    }

    private func writeCornerRadius(_ radius: CGFloat) {
        guard appliedCornerRadius.needsWrite(radius) else {
            return
        }
        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            effectView.layer?.cornerRadius = radius
        }
        tintOverlay?.layer?.cornerRadius = radius
    }

    func applyShadow() {

        // Apply on `effectView` (NSVisualEffectView) rather than `self` so the
        // shadow tracks the blurred surface's rounded bounds directly. Putting
        // it on the wrapper draws a rectangular shadow outside the visible
        // rounded glass, which leaks past the corners.
        if hasShadow, !usesGlass {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.12)
            s.shadowOffset = NSMakeSize(0, 0)
            s.shadowBlurRadius = 15
            self.shadow = s
        } else {
            self.shadow = nil
        }
    }

    private func applyShadowPath() {
        // No-op: NSView.shadow handles rendering automatically.
    }

    private func applyBorder() {
        let key = LiquidGlassBorderKey(usesGlass: usesGlass, hasBorder: hasBorder, isDark: presentation.colors.isDark, highContrast: accessibilityState.increaseContrast)
        guard appliedBorder.needsWrite(key) else {
            return
        }
        guard !key.usesGlass else {
            effectView.layer?.borderWidth = 0
            return
        }
        if key.highContrast {
            let borderColor = key.isDark
                ? NSColor.white.withAlphaComponent(0.55)
                : NSColor.black.withAlphaComponent(0.55)
            effectView.layer?.borderColor = borderColor.cgColor
            effectView.layer?.borderWidth = 1
        } else if key.hasBorder {
            let borderColor = key.isDark
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor.black.withAlphaComponent(0.04)
            effectView.layer?.borderColor = borderColor.cgColor
            effectView.layer?.borderWidth = 0.5
        } else {
            effectView.layer?.borderWidth = 0
        }
    }

    open override func layout() {
        super.layout()
        if bounds.size == validLayout { return }
        updateLayout(size: bounds.size, transition: .immediate)
    }
    
    open override var isHidden: Bool {
        didSet {
            self.effectView.isHidden = isHidden
            self.appearanceContainer.isHidden = isHidden
        }
    }
    
    func updateCornerRadius(size: NSSize) {
        writeCornerRadius(min(cornerRadius, min(size.width, size.height) / 2))
    }

    open func updateLayout(size: NSSize, transition: ContainedViewLayoutTransition) {
        let containerFrame = NSRect(origin: .zero, size: size)
        updateCornerRadius(size: size)

        if size == validLayout { return }
        validLayout = size
        if effectView.superview === self {
            transition.updateFrame(view: effectView, frame: containerFrame)
        }

        if let tintOverlay = tintOverlay {
            transition.updateFrame(view: tintOverlay, frame: containerFrame)
        }
        applyShadowPath()
    }


}

struct LiquidGlassRebuildKey: Equatable {
    let usesGlass: Bool
    let blurEnabled: Bool
    let forceAppearance: LiquidGlassAppearance
}

struct LiquidGlassBorderKey: Equatable {
    let usesGlass: Bool
    let hasBorder: Bool
    let isDark: Bool
    let highContrast: Bool
}
