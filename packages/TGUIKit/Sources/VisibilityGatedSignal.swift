import Foundation
import SwiftSignalKit

public func whileVisible<T, E>(_ signal: Signal<T, E>, visible: Signal<Bool, NoError>) -> Signal<T, E> {
    return visible
    |> distinctUntilChanged
    |> castError(E.self)
    |> mapToSignal { isVisible -> Signal<T, E> in
        return isVisible ? signal : .never()
    }
}
