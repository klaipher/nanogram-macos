import Cocoa
import SettingsUI
import NanogramDebugUI

func installDeveloperUIHooks() {
    DeveloperHooks.install(DeveloperHooks(
        updateGraphicContext: {
        appDelegate?.updateGraphicContext() },
        forceRLottieBackend: {
            return LottieBackend.forceRLottie
        },
        toggleForceRLottieBackend: {
            LottieBackend.forceRLottie = !LottieBackend.forceRLottie
        },
        openNanogramSwitches: {
            NanogramDebugMenu.showSwitches()
        }
    ))
}
