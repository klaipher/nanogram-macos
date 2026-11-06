import Foundation

struct AppliedValueCache<Value: Equatable> {
    private var applied: Value?

    mutating func needsWrite(_ value: Value) -> Bool {
        if self.applied == value {
            return false
        }
        self.applied = value
        return true
    }

    mutating func invalidate() {
        self.applied = nil
    }
}
