import Foundation

public struct CallBackgroundAnimationPolicy: Equatable {
    public var isInHierarchy: Bool
    public var isSuspended: Bool
    public var isEnergySavingEnabled: Bool
    public var isIdleOptimizationEnabled: Bool

    public init(isInHierarchy: Bool, isSuspended: Bool, isEnergySavingEnabled: Bool, isIdleOptimizationEnabled: Bool) {
        self.isInHierarchy = isInHierarchy
        self.isSuspended = isSuspended
        self.isEnergySavingEnabled = isEnergySavingEnabled
        self.isIdleOptimizationEnabled = isIdleOptimizationEnabled
    }

    public var shouldRunLink: Bool {
        guard self.isInHierarchy else {
            return false
        }
        guard self.isIdleOptimizationEnabled else {
            return true
        }
        return !self.isSuspended && !self.isEnergySavingEnabled
    }
}

final class CallBackgroundLinkController {
    private let makeLink: (@escaping (CGFloat) -> Void) -> AnyObject
    private let tick: (CGFloat) -> Void
    private var link: AnyObject?

    var policy: CallBackgroundAnimationPolicy {
        didSet {
            if self.policy != oldValue {
                self.refresh()
            }
        }
    }

    var hasLink: Bool {
        return self.link != nil
    }

    init(policy: CallBackgroundAnimationPolicy, makeLink: @escaping (@escaping (CGFloat) -> Void) -> AnyObject, tick: @escaping (CGFloat) -> Void) {
        self.policy = policy
        self.makeLink = makeLink
        self.tick = tick
    }

    func refresh() {
        if self.policy.shouldRunLink {
            if self.link == nil {
                let tick = self.tick
                self.link = self.makeLink({ delta in
                    tick(delta)
                })
            }
        } else {
            self.link = nil
        }
    }
}
