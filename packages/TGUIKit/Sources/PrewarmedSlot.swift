import Foundation

/// Holds one pre-built value so the first use does not pay for building it (and for any
/// asynchronous first fill it performs). `take()` hands out the prewarmed value, or builds one
/// on demand when nothing was prewarmed.
public final class PrewarmedSlot<Value> {
    private let make: () -> Value
    private var value: Value?

    public init(make: @escaping () -> Value) {
        self.make = make
    }

    public var isWarm: Bool { return value != nil }

    public func prewarm() {
        if value == nil {
            value = make()
        }
    }

    public func take() -> Value {
        if let value = value {
            self.value = nil
            return value
        }
        return make()
    }

    public func discard() {
        value = nil
    }
}
