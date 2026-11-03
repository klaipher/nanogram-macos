import Cocoa
import SettingsUI
import NanogramDebugUI
import NanogramLogExport

func installDeveloperUIHooks() {
    DeveloperHooks.install(DeveloperHooks(
        forceRLottieBackend: {
            return LottieBackend.forceRLottie
        },
        toggleForceRLottieBackend: {
            LottieBackend.forceRLottie = !LottieBackend.forceRLottie
        },
        openNanogramSwitches: {
            NanogramDebugMenu.showSwitches()
        },
        logExports: NanogramLogExportKind.allCases.map { kind in
            return DeveloperLogExport(id: kind.rawValue, title: NanogramLogExportSpec.current(kind).menuTitle + "…", send: { window in
                NanogramLogExport.present(kind: kind, window: window)
            })
        },
        sendLogs: { window in
            NanogramLogExport.present(kind: .appLogs, window: window)
        }
    ))
}
