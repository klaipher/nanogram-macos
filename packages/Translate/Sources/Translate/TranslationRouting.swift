import Foundation
import SwiftSignalKit

public enum TranslationManualMode: Equatable {
    case enabled
    case alternative
}

public enum TranslationStep: Equatable {
    case server
    case onDevice
}

public enum ServerTranslationFailure: Error, Equatable {
    case tryAlternative
    case other
}

public enum TranslationRouting {
    public static func steps(mode: TranslationManualMode, onDeviceAvailable: Bool) -> [TranslationStep] {
        return onDeviceAvailable ? [.onDevice] : [.server]
    }

    public static func run<T>(_ steps: [TranslationStep], server: @escaping () -> Signal<T?, ServerTranslationFailure>, onDevice: @escaping () -> Signal<T?, NoError>) -> Signal<T, Translate.Error> {
        guard let step = steps.first else {
            return .fail(.generic)
        }
        let rest = Array(steps.dropFirst())
        let next: () -> Signal<T, Translate.Error> = {
            return run(rest, server: server, onDevice: onDevice)
        }
        switch step {
        case .server:
            return server()
            |> map { value -> T?? in
                return .some(value)
            }
            |> `catch` { error -> Signal<T??, Translate.Error> in
                switch error {
                case .tryAlternative:
                    return .single(.none)
                case .other:
                    return .fail(.generic)
                }
            }
            |> take(1)
            |> mapToSignal { value -> Signal<T, Translate.Error> in
                if case let .some(.some(result)) = value {
                    return .single(result)
                }
                return next()
            }
        case .onDevice:
            return onDevice()
            |> castError(Translate.Error.self)
            |> take(1)
            |> mapToSignal { value -> Signal<T, Translate.Error> in
                if let value = value {
                    return .single(value)
                }
                return next()
            }
        }
    }
}
