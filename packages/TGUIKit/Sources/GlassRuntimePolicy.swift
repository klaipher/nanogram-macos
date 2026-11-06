import Cocoa

public struct GlassAccessibilityState: Equatable, Sendable {
    public var reduceTransparency: Bool
    public var increaseContrast: Bool

    public init(reduceTransparency: Bool, increaseContrast: Bool) {
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
    }

    public var prefersOpaque: Bool {
        return reduceTransparency
    }

    @MainActor
    public static func current() -> GlassAccessibilityState {
        let workspace = NSWorkspace.shared
        return GlassAccessibilityState(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
    }
}

@MainActor
public protocol GlassEnvironmentListener: AnyObject {
    func glassEnvironmentDidChange()
}

@MainActor
public final class GlassAccessibilityMonitor {
    public static let shared = GlassAccessibilityMonitor(read: { GlassAccessibilityState.current() }, observesWorkspace: true)

    public private(set) var state: GlassAccessibilityState
    private let read: @MainActor () -> GlassAccessibilityState
    private var forcedState: GlassAccessibilityState?
    private let listeners = NSHashTable<AnyObject>.weakObjects()
    private var observer: NSObjectProtocol?

    public init(read: @escaping @MainActor () -> GlassAccessibilityState, observesWorkspace: Bool = false) {
        self.read = read
        self.state = read()
        if observesWorkspace {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    public func register(_ listener: GlassEnvironmentListener) {
        listeners.add(listener)
    }

    @discardableResult
    public func force(_ state: GlassAccessibilityState?) -> Bool {
        forcedState = state
        return refresh()
    }

    @discardableResult
    public func refresh() -> Bool {
        let updated = forcedState ?? read()
        guard updated != state else {
            return false
        }
        state = updated
        for listener in listeners.allObjects {
            (listener as? GlassEnvironmentListener)?.glassEnvironmentDidChange()
        }
        return true
    }
}

public enum GlassGroup: String, CaseIterable, Sendable {
    case chatHeader
    case inputRow
    case tabBar
    case toasts
}

public enum GlassDebug {
    public static func parse(_ value: String?) -> Set<GlassGroup> {
        guard let value else {
            return []
        }
        var result = Set<GlassGroup>()
        for part in value.split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if name == "all" {
                return Set(GlassGroup.allCases)
            }
            if let group = GlassGroup(rawValue: name) {
                result.insert(group)
            }
        }
        return result
    }

#if DEBUG
    public static let disabledGroups: Set<GlassGroup> = parse(UserDefaults.standard.string(forKey: "GlassDisable"))
#else
    public static let disabledGroups: Set<GlassGroup> = []
#endif

    public static func isDisabled(_ group: GlassGroup?) -> Bool {
        guard let group else {
            return false
        }
        return disabledGroups.contains(group)
    }
}
