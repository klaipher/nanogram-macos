import Cocoa
import SettingsUI
import NanogramDebugUI
import NanogramLogExport
import HTMLBubbles

func installDeveloperUIHooks() {
    DeveloperHooks.install(DeveloperHooks(
        openNanogramSwitches: {
            NanogramDebugMenu.showSwitches()
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
