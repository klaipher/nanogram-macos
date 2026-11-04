import Foundation
import os

public enum PerformanceSignposts {
    public static let category = "Performance"

    @available(macOS 12.0, *)
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "Telegram", category: PerformanceSignposts.category)

    public struct State {
        fileprivate let name: StaticString
        fileprivate let value: Any?
    }

    @inline(__always)
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = PerformanceSignposts.begin(name)
        defer {
            PerformanceSignposts.end(name, state)
        }
        return try body()
    }

    public static func begin(_ name: StaticString) -> State {
        if #available(macOS 12.0, *) {
            let signposter = PerformanceSignposts.signposter
            guard signposter.isEnabled else {
                return State(name: name, value: nil)
            }
            return State(name: name, value: signposter.beginInterval(name))
        } else {
            return State(name: name, value: nil)
        }
    }

    public static func end(_ name: StaticString, _ state: State) {
        if #available(macOS 12.0, *) {
            if let value = state.value as? OSSignpostIntervalState {
                PerformanceSignposts.signposter.endInterval(name, value)
            }
        }
    }

    public final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private let name: StaticString
        private var state: State?

        public init(_ name: StaticString) {
            self.name = name
            self.state = PerformanceSignposts.begin(name)
        }

        public func end() {
            lock.lock()
            let current = state
            state = nil
            lock.unlock()
            if let current {
                PerformanceSignposts.end(name, current)
            }
        }
    }
}
