import Foundation

public final class LazyGlassGhostSlot<Ghost: AnyObject> {
    private let make: () -> Ghost
    private let attach: (Ghost) -> Void
    public private(set) var ghost: Ghost?
    public private(set) var creationCount: Int = 0

    public init(make: @escaping () -> Ghost, attach: @escaping (Ghost) -> Void) {
        self.make = make
        self.attach = attach
    }

    public var isCreated: Bool {
        return ghost != nil
    }

    public static func shouldCreate(isCreated: Bool, isNeeded: Bool) -> Bool {
        return !isCreated && isNeeded
    }

    @discardableResult
    public func resolve(isNeeded: Bool) -> Ghost? {
        if let ghost {
            return ghost
        }
        guard Self.shouldCreate(isCreated: false, isNeeded: isNeeded) else {
            return nil
        }
        let created = make()
        ghost = created
        creationCount += 1
        attach(created)
        return created
    }
}
