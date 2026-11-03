/// What the direct edition's updater shows, driven by Sparkle 2's user-driver callbacks.
///
/// Sparkle 2 reports an update through separate callbacks (found, download length, bytes, extraction, ready);
/// this folds them into one phase for the app's update row, button and window. A scheduled background check
/// must never hide an update that is already downloading or waiting to install, and progress callbacks that
/// arrive without a known update are ignored. `Item` is Sparkle's appcast item in the app, a string in tests.
public struct UpdateFlow<Item: Equatable>: Equatable {
    public enum Phase: Equatable {
        case idle
        case checking
        case found(Item)
        case downloading(Item, received: UInt64, expected: UInt64)
        case extracting(Item)
        case readyToInstall(Item)
        case installing
        case upToDate
        case failed(String)
    }

    public enum Event: Equatable {
        case checkStarted
        case found(Item)
        case notFound
        case downloadStarted
        case expectedLength(UInt64)
        case received(UInt64)
        case extractionStarted
        case ready
        case installing
        case failed(String)
        case dismissed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var item: Item?

    public init() {}

    private var isBusy: Bool {
        switch phase {
        case .downloading, .extracting, .readyToInstall, .installing: true
        default: false
        }
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case .checkStarted:
            if !isBusy { phase = .checking }
        case let .found(found):
            item = found
            phase = .found(found)
        case .notFound:
            if !isBusy { phase = .upToDate }
        case .downloadStarted:
            if let item { phase = .downloading(item, received: 0, expected: 0) }
        case let .expectedLength(length):
            if let item { phase = .downloading(item, received: 0, expected: length) }
        case let .received(length):
            guard let item else { return }
            var received = length
            var expected: UInt64 = 0
            if case let .downloading(_, soFar, announced) = phase {
                received += soFar
                expected = announced
            }
            phase = .downloading(item, received: received, expected: max(expected, received))
        case .extractionStarted:
            if let item { phase = .extracting(item) }
        case .ready:
            if let item { phase = .readyToInstall(item) }
        case .installing:
            if item != nil { phase = .installing }
        case let .failed(message):
            item = nil
            phase = .failed(message)
        case .dismissed:
            if case .found = phase {
                item = nil
                phase = .idle
            }
        }
    }
}

extension UpdateFlow: Sendable where Item: Sendable {}
extension UpdateFlow.Phase: Sendable where Item: Sendable {}
extension UpdateFlow.Event: Sendable where Item: Sendable {}
