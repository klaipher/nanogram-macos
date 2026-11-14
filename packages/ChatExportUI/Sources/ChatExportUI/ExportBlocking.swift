import Foundation
import Postbox
import SwiftSignalKit

enum ExportBlocking {
    static func first<T>(_ signal: Signal<T, NoError>, timeout: Double, pollInterval: Double = 0.2, isCancelled: () -> Bool, onTick: () -> Void = {}) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Atomic<T?>(value: nil)
        let disposable = signal.start(next: { value in
            _ = result.swap(value)
            semaphore.signal()
        }, completed: {
            semaphore.signal()
        })
        let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : Date.distantFuture
        while semaphore.wait(timeout: .now() + pollInterval) == .timedOut {
            if isCancelled() || Date() > deadline {
                disposable.dispose()
                return nil
            }
            onTick()
        }
        disposable.dispose()
        return result.with { $0 }
    }

    static func completeResource(mediaBox: MediaBox, resource: MediaResource, timeout: Double, isCancelled: () -> Bool, onTick: () -> Void = {}) -> MediaResourceData? {
        let signal = mediaBox.resourceData(resource) |> filter { $0.complete } |> take(1)
        return first(signal, timeout: timeout, isCancelled: isCancelled, onTick: onTick)
    }
}
