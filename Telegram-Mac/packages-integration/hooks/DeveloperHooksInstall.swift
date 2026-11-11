import Cocoa
import SettingsUI
import NanogramDebugUI
import NanogramLogExport

func installDeveloperUIHooks() {
    DeveloperHooks.install(DeveloperHooks(
        openNanogramSwitches: {
            NanogramDebugMenu.showSwitches()
        },
        logExports: NanogramLogExportKind.allCases.filter(nanogramLogExportKindIsAvailable).map { kind in
            return DeveloperLogExport(id: kind.rawValue, title: NanogramLogExportSpec.current(kind).menuTitle + "…", send: { window in
                NanogramLogExport.present(kind: kind, window: window)
            })
        },
        sendLogs: { window in
            NanogramLogExport.present(kind: .appLogs, window: window)
        }
    ))
}
