import Cocoa

public struct GlassGhostSpec: Hashable {
    public let cornerRadius: CGFloat
    public let hasShadow: Bool
    public let hasBorder: Bool
    public let tintAlpha: CGFloat
    public let group: GlassGroup?

    public init(cornerRadius: CGFloat, hasShadow: Bool = true, hasBorder: Bool = true, tintAlpha: CGFloat = 0.3, group: GlassGroup? = nil) {
        self.cornerRadius = cornerRadius
        self.hasShadow = hasShadow
        self.hasBorder = hasBorder
        self.tintAlpha = tintAlpha
        self.group = group
    }

    func makeView() -> LiquidGlassView {
        let view = LiquidGlassView(frame: .zero, cornerRadius: cornerRadius, hasShadow: hasShadow, hasBorder: hasBorder, tintAlpha: tintAlpha)
        view.glassGroup = group
        return view
    }
}

public final class GlassGhostPool {
    public static let shared = GlassGhostPool()

    public var capacity: Int = 12
    public private(set) var createdCount = 0
    public private(set) var reusedCount = 0
    public private(set) var droppedCount = 0
    private var storage: [GlassGhostSpec: [LiquidGlassView]] = [:]

    public init() {}

    public var pooledCount: Int {
        return storage.values.reduce(0) { $0 + $1.count }
    }

    public func acquire(_ spec: GlassGhostSpec) -> LiquidGlassView {
        guard GlassChromeReuse.isEnabled else {
            return spec.makeView()
        }
        if var list = storage[spec], let view = list.popLast() {
            storage[spec] = list
            reusedCount += 1
            view.resetForGlassReuse()
            view.glassGroup = spec.group
            view.glassReuseSpec = spec
            return view
        }
        createdCount += 1
        let view = spec.makeView()
        view.glassReuseSpec = spec
        return view
    }

    public func release(_ view: LiquidGlassView) {
        guard let spec = view.glassReuseSpec else {
            return
        }
        view.glassReuseSpec = nil
        guard GlassChromeReuse.isEnabled, Thread.isMainThread, pooledCount < capacity else {
            droppedCount += 1
            return
        }
        view.resetForGlassReuse()
        storage[spec, default: []].append(view)
    }

    public func release(from container: GlassContainerView) {
        for ghost in container.ghosts where ghost.glassReuseSpec != nil {
            container.removeGhost(ghost)
            release(ghost)
        }
    }

    public func drain() {
        storage.removeAll()
    }
}
