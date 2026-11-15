import Cocoa
import TGUIKit
@preconcurrency import InputDataUI
import GeneralRows
import TelegramTheme
import ColorPalette

private enum NanogramResetIds {
    static let reset = InputDataIdentifier("_id_nanogram_reset")
}

/// Nanogram's debug switches as ordinary settings sections; the one upstream hook calls this.
func nanogramDeveloperEntries(sectionId: inout Int32, index: inout Int32, changed: @escaping () -> Void) -> [InputDataEntry] {
    guard DeveloperHooks.isInstalled, let makeSections = DeveloperHooks.shared.nanogramSections else {
        return []
    }
    var entries = nanogramOptionEntries(sections: makeSections(), sectionId: &sectionId, index: &index, changed: changed)
    if !entries.isEmpty, let reset = DeveloperHooks.shared.resetNanogramSections {
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: NanogramResetIds.reset, data: InputDataGeneralData(name: "Reset Nanogram Switches", color: theme.colors.redUI, type: .none, viewType: .singleItem, action: {
            reset()
            changed()
        })))
        index += 1
        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1
    }
    return entries
}

func nanogramOptionEntries(sections: [DeveloperOptionSection], sectionId: inout Int32, index: inout Int32, changed: @escaping () -> Void) -> [InputDataEntry] {
    var entries: [InputDataEntry] = []
    for section in sections where !section.options.isEmpty {
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain(section.title.uppercased()), data: .init(viewType: .textTopItem)))
        index += 1
        for (offset, option) in section.options.enumerated() {
            let viewType: GeneralViewType = section.options.count == 1 ? .singleItem : (offset == 0 ? .firstItem : (offset == section.options.count - 1 ? .lastItem : .innerItem))
            let identifier = InputDataIdentifier("_id_nanogram_\(option.id)")
            switch option.kind {
            case let .toggle(isOn, set):
                entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: identifier, data: InputDataGeneralData(name: option.title, color: theme.colors.text, type: .switchable(isOn), viewType: viewType, action: {
                    set(!isOn)
                    changed()
                })))
            case let .choice(titles, selected, select):
                let items = titles.enumerated().map { entry in
                    return ContextMenuItem(entry.element, handler: {
                        select(entry.offset)
                        changed()
                    })
                }
                let value = titles.indices.contains(selected) ? titles[selected] : ""
                entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: identifier, data: InputDataGeneralData(name: option.title, color: theme.colors.text, type: .contextSelector(value, items), viewType: viewType)))
            }
            index += 1
        }
        let notes = section.options.flatMap { option -> [String] in
            return [option.footnote.map { option.title + ": " + $0 }, option.stats.map { option.title + ": " + $0 }].compactMap { $0 }
        }
        if !notes.isEmpty {
            entries.append(.desc(sectionId: sectionId, index: index, text: .plain(notes.joined(separator: "\n")), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
            index += 1
        }
        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1
    }
    return entries
}
