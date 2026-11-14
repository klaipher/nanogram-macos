import Foundation
import SwiftSignalKit

final class UserInitiatedActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var token: (any NSObjectProtocol)?
    private let endActivity: (any NSObjectProtocol) -> Void

    init(
        reason: String,
        begin: (ProcessInfo.ActivityOptions, String) -> any NSObjectProtocol = { ProcessInfo.processInfo.beginActivity(options: $0, reason: $1) },
        end: @escaping (any NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.token = begin([.userInitiatedAllowingIdleSystemSleep], reason)
        self.endActivity = end
    }

    func end() {
        lock.lock()
        let current = token
        token = nil
        lock.unlock()
        if let current {
            endActivity(current)
        }
    }

    deinit {
        end()
    }
}

extension Signal {
    func holdingUserInitiatedActivity(reason: String, make: @escaping (String) -> UserInitiatedActivity = { UserInitiatedActivity(reason: $0) }) -> Signal<T, E> {
        return Signal<T, E> { subscriber in
            let activity = make(reason)
            let disposable = self.start(next: { value in
                subscriber.putNext(value)
            }, error: { error in
                activity.end()
                subscriber.putError(error)
            }, completed: {
                activity.end()
                subscriber.putCompletion()
            })
            return ActionDisposable {
                disposable.dispose()
                activity.end()
            }
        }
    }
}
