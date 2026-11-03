import Foundation
import SwiftSignalKit
import Reachability

public final class AutomaticDownloadDataSaving {
    public static let shared = AutomaticDownloadDataSaving(networkSignal: combineLatest(Reachability.isConstrained, Reachability.isExpensive) |> map { isConstrained, isExpensive in
        return isConstrained || isExpensive
    })
    
    private let state = Atomic<Bool>(value: false)
    private let statePromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private var disposable: Disposable?
    
    init(networkSignal: Signal<Bool, NoError>) {
        self.disposable = (networkSignal |> distinctUntilChanged).start(next: { [weak self] value in
            guard let self else {
                return
            }
            let _ = self.state.swap(value)
            self.statePromise.set(value)
        })
    }
    
    deinit {
        self.disposable?.dispose()
    }
    
    public var isSavingData: Bool {
        return self.state.with { $0 }
    }
    
    public var isSavingDataSignal: Signal<Bool, NoError> {
        return self.statePromise.get()
    }
}

public extension AutomaticMediaDownloadSettings {
    func pausesLargeMediaDownloads(isSavingData: Bool) -> Bool {
        return self.respectLowDataMode && isSavingData
    }
}
