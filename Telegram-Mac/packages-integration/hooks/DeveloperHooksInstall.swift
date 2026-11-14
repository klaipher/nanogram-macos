import Cocoa
import SettingsUI
import NanogramDebugUI
import NanogramLogExport
import NanogramDebug
import HTMLBubbles

private func developerOptionSections(userFacing: Bool) -> [DeveloperOptionSection] {
    let settings = NanogramDebugSettings.shared
    let ledger = NanogramEnergyLedger.shared
    let stats: (String) -> String? = { userFacing ? nil : ledger.summary(for: $0) }
    return settings.sections(userFacing: userFacing).map { section in
        DeveloperOptionSection(title: section.title, options: section.options.map { option in
            switch option.kind {
            case .toggle:
                return DeveloperOption(id: option.id, title: option.title, footnote: userFacing ? option.userFootnote : option.footnote, stats: stats(option.id), kind: .toggle(isOn: settings.bool(option.id), set: { settings.set(option.id, bool: $0) }))
            case let .choice(choices, _):
                let selected = settings.choice(option.id).flatMap { value in choices.firstIndex(where: { $0.id == value }) } ?? 0
                return DeveloperOption(id: option.id, title: option.title, footnote: userFacing ? option.userFootnote : option.footnote, stats: stats(option.id), kind: .choice(titles: choices.map { $0.title }, selected: selected, select: { index in
                    if choices.indices.contains(index) {
                        settings.set(option.id, choice: choices[index].id)
                    }
                }))
            }
        })
    }
}

func installDeveloperUIHooks() {
    DeveloperHooks.install(DeveloperHooks(
        nanogramSections: {
            return developerOptionSections(userFacing: false)
        },
        resetNanogramSections: {
            NanogramDebugSettings.shared.resetAll()
        },
        nanogramFeatureSections: {
            return developerOptionSections(userFacing: true)
        },
        resetNanogramFeatures: {
            NanogramDebugSettings.shared.resetUserFacing()
        },
        messageWidgets: DeveloperSwitch(isOn: {
            return MessageWidgetsSwitch.isEnabled
        }, setOn: { enabled in
            MessageWidgetsSwitch.setEnabled(enabled)
        }),
        logExports: NanogramLogExportKind.allCases.filter(nanogramLogExportKindIsAvailable).map { kind in
            return DeveloperLogExport(id: kind.rawValue, title: NanogramLogExportSpec.current(kind).menuTitle + "…", send: { window in
                NanogramLogExport.present(kind: kind, window: window)
            })
        },
        sendLogs: { window in
            NanogramLogExport.present(kind: .fullReport, window: window)
        }
    ))
}
