import Foundation
import SwiftSignalKit
import Postbox
import TGUIKit

public struct ProgressSample: Equatable {
    public let progress: Float
    public let kind: Int

    public init(progress: Float, kind: Int) {
        self.progress = progress
        self.kind = kind
    }
}

public struct ProgressCoalescer<Value> {
    public enum Decision {
        case emit(Value)
        case hold(after: Double)
    }

    private let minDelta: Float
    private let minInterval: Double
    private let classify: (Value) -> ProgressSample?
    private var lastEmitted: ProgressSample?
    private var lastEmitTime: Double = 0
    private var pending: Value?

    public init(minDelta: Float, minInterval: Double, classify: @escaping (Value) -> ProgressSample?) {
        self.minDelta = minDelta
        self.minInterval = minInterval
        self.classify = classify
    }

    public mutating func accept(_ value: Value, now: Double) -> Decision {
        guard let sample = classify(value) else {
            pending = nil
            lastEmitted = nil
            return .emit(value)
        }
        guard let last = lastEmitted, last.kind == sample.kind, sample.progress < 1.0 else {
            return emit(value, sample: sample, now: now)
        }
        let elapsed = now - lastEmitTime
        if elapsed >= minInterval && abs(sample.progress - last.progress) >= minDelta {
            return emit(value, sample: sample, now: now)
        }
        pending = value
        return .hold(after: max(minInterval - elapsed, 0))
    }

    public mutating func flush(now: Double, force: Bool = true) -> Value? {
        guard let value = pending else {
            return nil
        }
        if !force, let sample = classify(value), let last = lastEmitted, last.kind == sample.kind, abs(sample.progress - last.progress) < minDelta {
            return nil
        }
        pending = nil
        if let sample = classify(value) {
            lastEmitted = sample
            lastEmitTime = now
        }
        return value
    }

    private mutating func emit(_ value: Value, sample: ProgressSample, now: Double) -> Decision {
        pending = nil
        lastEmitted = sample
        lastEmitTime = now
        return .emit(value)
    }
}

private final class CoalescerState<T> {
    private var coalescer: ProgressCoalescer<T>
    private var generation = 0
    private var finished = false

    init(_ coalescer: ProgressCoalescer<T>) {
        self.coalescer = coalescer
    }

    func accept(_ value: T, now: Double) -> (ProgressCoalescer<T>.Decision, Int) {
        generation += 1
        return (coalescer.accept(value, now: now), generation)
    }

    func flush(ifGeneration expected: Int, now: Double) -> T? {
        guard !finished, generation == expected else {
            return nil
        }
        return coalescer.flush(now: now, force: false)
    }

    func finish(now: Double) -> T? {
        generation += 1
        finished = true
        return coalescer.flush(now: now)
    }

    func cancel() {
        generation += 1
        finished = true
    }
}

public extension Signal {
    func coalescedProgress(minDelta: Float = 0.01, minInterval: Double = 1.0 / 30.0, classify: @escaping (T) -> ProgressSample?) -> Signal<T, E> {
        return Signal<T, E> { subscriber in
            let state = CoalescerState(ProgressCoalescer<T>(minDelta: minDelta, minInterval: minInterval, classify: classify))
            let queue = Queue(name: "nanogram.coalescedProgress")

            let source = self.start(next: { value in
                queue.async {
                    let (decision, generation) = state.accept(value, now: CFAbsoluteTimeGetCurrent())
                    switch decision {
                    case let .emit(value):
                        subscriber.putNext(value)
                    case let .hold(delay):
                        queue.after(delay + 0.002, {
                            if let flushed = state.flush(ifGeneration: generation, now: CFAbsoluteTimeGetCurrent()) {
                                subscriber.putNext(flushed)
                            }
                        })
                    }
                }
            }, error: { error in
                queue.async {
                    state.cancel()
                    subscriber.putError(error)
                }
            }, completed: {
                queue.async {
                    if let flushed = state.finish(now: CFAbsoluteTimeGetCurrent()) {
                        subscriber.putNext(flushed)
                    }
                    subscriber.putCompletion()
                }
            })

            return ActionDisposable {
                queue.async {
                    state.cancel()
                }
                source.dispose()
            }
        }
    }
}

public extension ProgressSample {
    static func of(_ status: MediaResourceStatus) -> ProgressSample? {
        switch status {
        case let .Fetching(isActive, progress):
            return ProgressSample(progress: progress, kind: isActive ? 1 : 2)
        case let .Remote(progress):
            return progress > 0 ? ProgressSample(progress: progress, kind: 3) : nil
        case .Local, .Paused:
            return nil
        }
    }

    static func of(updating progress: Float?) -> ProgressSample? {
        return progress.map { ProgressSample(progress: $0, kind: 4) }
    }
}

public extension Signal where T == MediaResourceStatus {
    func coalescedStatusProgress() -> Signal<MediaResourceStatus, E> {
        guard ModernizationFlag.coalescedMediaProgress.isEnabled else {
            return self
        }
        return coalescedProgress(classify: ProgressSample.of(_:))
    }
}

public extension Signal where T == Float? {
    func coalescedUpdatingProgress() -> Signal<Float?, E> {
        guard ModernizationFlag.coalescedMediaProgress.isEnabled else {
            return self
        }
        return coalescedProgress(classify: ProgressSample.of(updating:))
    }
}

/// Pipe forms for `signal |> coalescedStatusProgress()`, the style of the ChatUI call sites.
public func coalescedStatusProgress<E>() -> (Signal<MediaResourceStatus, E>) -> Signal<MediaResourceStatus, E> {
    return { signal in signal.coalescedStatusProgress() }
}

public func coalescedUpdatingProgress<E>() -> (Signal<Float?, E>) -> Signal<Float?, E> {
    return { signal in signal.coalescedUpdatingProgress() }
}
