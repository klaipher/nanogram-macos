import Foundation

public final class OneShotGate {
    public private(set) var hasRun = false

    public init() {
    }

    public func run(_ work: () -> Void) {
        guard !self.hasRun else {
            return
        }
        self.hasRun = true
        work()
    }

    public func reset() {
        self.hasRun = false
    }
}
