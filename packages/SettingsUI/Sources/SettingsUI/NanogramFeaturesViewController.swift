import Cocoa
import TGUIKit
import SwiftSignalKit
@preconcurrency import InputDataUI
import GeneralRows
import TelegramContext
import TelegramTheme

private struct State: Equatable {
    var revision: Int = 0
}

private enum NanogramFeaturesIds {
    static let reset = InputDataIdentifier("_id_nanogram_features_reset")
}

private func entries(_ state: State, changed: @escaping () -> Void) -> [InputDataEntry] {
    var entries: [InputDataEntry] = []
    var sectionId: Int32 = 0
    var index: Int32 = 0

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    guard DeveloperHooks.isInstalled, let makeSections = DeveloperHooks.shared.nanogramFeatureSections else {
        return entries
    }
    entries.append(contentsOf: nanogramOptionEntries(sections: makeSections(), sectionId: &sectionId, index: &index, changed: changed))

    if let reset = DeveloperHooks.shared.resetNanogramFeatures {
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: NanogramFeaturesIds.reset, data: InputDataGeneralData(name: "Reset to Defaults", color: theme.colors.redUI, type: .none, viewType: .singleItem, action: { //TODOLANG
            reset()
            changed()
        })))
        index += 1
        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1
    }
    return entries
}

public func NanogramFeaturesViewController(context: any AccountContextProtocol) -> InputDataController {
    let statePromise = ValuePromise(State(), ignoreRepeated: true)
    let stateValue = Atomic(value: State())
    let updateState: ((State) -> State) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let changed: () -> Void = {
        updateState { current in
            var current = current
            current.revision += 1
            return current
        }
    }

    let signal = statePromise.get() |> deliverOnPrepareQueue |> map { state in
        return InputDataSignalValue(entries: entries(state, changed: changed))
    }

    return InputDataController(dataSignal: signal, title: "Nanogram Features", hasDone: false) //TODOLANG
}
