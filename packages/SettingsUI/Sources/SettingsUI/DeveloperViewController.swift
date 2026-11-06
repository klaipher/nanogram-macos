import Cocoa
import TGUIKit
import SwiftSignalKit
import TelegramCore
import ApiCredentials
import MtProtoKit
import Postbox
import ThemeSettings
import InputDataUI
import GeneralRows
import Localization
import TelegramContext
import TelegramUtils
import TelegramTheme
import ColorPalette
import FoundationUtils
import AccountResetSupport
import AlertsUI
import InAppSettings


private final class Arguments {
    public let context: any AccountContextProtocol
    public let toggleLogs: (Bool) -> Void
    public let navigateToLogs: () -> Void
    public let addAccount: () -> Void
    public let toggleMenu: (Bool) -> Void
    public let toggleDebugWebApp: () -> Void
    public let toggleNetwork: () -> Void
    public let selectNetworkEngine: (NetworkEngineKind) -> Void
    public let toggleDownloads: () -> Void
    public let memoryReport: () -> Void
    public let toggleAccessibilityTree: () -> Void
    public let accessibilityAudit: () -> Void
    public let toggleForceRLottieBackend: () -> Void
    public let toggleGlassGrouping: () -> Void
    public let resetApp: (DeveloperAppReset) -> Void
    public init(context: any AccountContextProtocol,
         toggleLogs: @escaping (Bool) -> Void,
         navigateToLogs: @escaping () -> Void,
         addAccount: @escaping () -> Void,
         toggleMenu: @escaping (Bool) -> Void,
         toggleDebugWebApp: @escaping () -> Void,
         toggleNetwork: @escaping () -> Void,
         selectNetworkEngine: @escaping (NetworkEngineKind) -> Void,
         toggleDownloads: @escaping () -> Void,
         memoryReport: @escaping () -> Void,
         toggleAccessibilityTree: @escaping () -> Void,
         accessibilityAudit: @escaping () -> Void,
         toggleForceRLottieBackend: @escaping () -> Void,
         toggleGlassGrouping: @escaping () -> Void,
         resetApp: @escaping (DeveloperAppReset) -> Void) {
        self.context = context
        self.toggleLogs = toggleLogs
        self.navigateToLogs = navigateToLogs
        self.addAccount = addAccount
        self.toggleMenu = toggleMenu
        self.toggleDebugWebApp = toggleDebugWebApp
        self.toggleNetwork = toggleNetwork
        self.selectNetworkEngine = selectNetworkEngine
        self.toggleDownloads = toggleDownloads
        self.memoryReport = memoryReport
        self.toggleAccessibilityTree = toggleAccessibilityTree
        self.accessibilityAudit = accessibilityAudit
        self.toggleForceRLottieBackend = toggleForceRLottieBackend
        self.toggleGlassGrouping = toggleGlassGrouping
        self.resetApp = resetApp
    }
}

private struct State: Equatable {
    public var logToFile: Bool = false
    public var legacyMenu: Bool = false
    public var debugWebApp: Bool = false
    public var useNetworkFramework: Bool = false
    public var networkEngine: NetworkEngineKind = .mtProtoKit
    public var activeNetworkEngine: NetworkEngineKind = .mtProtoKit
    public var useExperimentalDownload: Bool = true
    public var accessibilityTree: Bool = true
    public var forceRLottieBackend: Bool = false
    public var glassGroupingSecondary: Bool = false
}

private let _id_add_account = InputDataIdentifier("_id_add_account")
private let _id_toggle_logs = InputDataIdentifier("_id_toggle_logs")
private let _id_open_logs = InputDataIdentifier("_id_open_logs")
private let _id_toggle_menu = InputDataIdentifier("_id_toggle_menu")
private let _id_debug_web_app = InputDataIdentifier("_id_debug_web_app")
private let _id_network = InputDataIdentifier("_id_network")
private let _id_network_engine = InputDataIdentifier("_id_network_engine")
private let _id_downloads = InputDataIdentifier("_id_downloads")
private let _id_memory_report = InputDataIdentifier("_id_memory_report")
private let _id_accessibility_tree = InputDataIdentifier("_id_accessibility_tree")
private let _id_accessibility_audit = InputDataIdentifier("_id_accessibility_audit")
private let _id_force_rlottie = InputDataIdentifier("_id_force_rlottie")
private let _id_glass_grouping = InputDataIdentifier("_id_glass_grouping")
private let _id_clear_database = InputDataIdentifier("_id_clear_database")
private let _id_clear_database_and_cache = InputDataIdentifier("_id_clear_database_and_cache")
private let _id_nanogram_switches = InputDataIdentifier("_id_nanogram_switches")


private func entries(_ state: State, arguments: Arguments) -> [InputDataEntry] {
    var entries: [InputDataEntry] = []

    var sectionId: Int32 = 0
    var index: Int32 = 0

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    if DeveloperHooks.isInstalled, let openNanogramSwitches = DeveloperHooks.shared.openNanogramSwitches {
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("NANOGRAM"), data: .init(viewType: .textTopItem)))
        index += 1

        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_nanogram_switches, data: InputDataGeneralData(name: "Debug Switches…", color: theme.colors.text, type: .next, viewType: .singleItem, action: openNanogramSwitches)))
        index += 1

        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1
    }

    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("ACCOUNTS"), data: .init(viewType: .textTopItem)))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_add_account, data: InputDataGeneralData(name: "Add Account", color: theme.colors.text, type: .next, viewType: .singleItem, action: arguments.addAccount)))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("LOGS"), data: .init(viewType: .textTopItem)))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_toggle_logs, data: InputDataGeneralData(name: "Enable Logs", color: theme.colors.text, type: .switchable(state.logToFile), viewType: .firstItem, action: {
        arguments.toggleLogs(!state.logToFile)
    })))
    index += 1

    let logExports = DeveloperHooks.isInstalled ? DeveloperHooks.shared.logExports : []
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_open_logs, data: InputDataGeneralData(name: "Open Logs", color: theme.colors.text, type: .next, viewType: logExports.isEmpty ? .lastItem : .innerItem, action: arguments.navigateToLogs)))
    index += 1

    for (offset, export) in logExports.enumerated() {
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("_id_send_logs_\(export.id)"), data: InputDataGeneralData(name: export.title, color: theme.colors.accent, type: .none, viewType: offset == logExports.count - 1 ? .lastItem : .innerItem, action: {
            export.send(arguments.context.window)
        })))
        index += 1
    }

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("INTERFACE"), data: .init(viewType: .textTopItem)))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_toggle_menu, data: InputDataGeneralData(name: "Native Context Menus (NSMenu)", color: theme.colors.text, type: .switchable(state.legacyMenu), viewType: .firstItem, action: {
        arguments.toggleMenu(!state.legacyMenu)
    })))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_force_rlottie, data: InputDataGeneralData(name: "Lottie: rlottie instead of tlottie", color: theme.colors.text, type: .switchable(state.forceRLottieBackend), viewType: .innerItem, action: arguments.toggleForceRLottieBackend)))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_glass_grouping, data: InputDataGeneralData(name: "Glass: group secondary screens (reopen the screen)", color: theme.colors.text, type: .switchable(state.glassGroupingSecondary), viewType: .lastItem, action: arguments.toggleGlassGrouping)))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("NETWORK"), data: .init(viewType: .textTopItem)))
    index += 1

    let networkEngineTitle: (NetworkEngineKind) -> String = { engine in
        switch engine {
        case .mtProtoKit:
            return "MtProtoKit"
        case .rust:
            return "Rust"
        }
    }
    var networkEngineValue = networkEngineTitle(state.networkEngine)
    if state.networkEngine != state.activeNetworkEngine {
        networkEngineValue += " (active: \(networkEngineTitle(state.activeNetworkEngine)))"
    }
    let networkEngineItems: [ContextMenuItem] = [
        ContextMenuItem("MtProtoKit", handler: {
            arguments.selectNetworkEngine(.mtProtoKit)
        }),
        ContextMenuItem("Rust (restart required)", handler: {
            arguments.selectNetworkEngine(.rust)
        })
    ]
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_network_engine, data: InputDataGeneralData(name: "Network Engine", color: theme.colors.text, type: .contextSelector(networkEngineValue, networkEngineItems), viewType: .firstItem)))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_downloads, data: InputDataGeneralData(name: "Downloads v2 (restart required)", color: theme.colors.text, type: .switchable(state.useExperimentalDownload), viewType: .innerItem, action: arguments.toggleDownloads)))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_network, data: InputDataGeneralData(name: "MtProtoKit: Network.framework TCP (restart required)", color: theme.colors.text, type: .switchable(state.useNetworkFramework), viewType: .lastItem, action: arguments.toggleNetwork)))
    index += 1

    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Downloads v2 is the newer cloud-media downloader; it is on by default and the server can switch it off. The Network.framework transport applies only while MtProtoKit runs; it stays off until its keepalive fix reaches the macOS core."), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("DEBUGGING"), data: .init(viewType: .textTopItem)))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_debug_web_app, data: InputDataGeneralData(name: "Debug Web App", color: theme.colors.text, type: .switchable(state.debugWebApp), viewType: .firstItem, action: arguments.toggleDebugWebApp)))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_memory_report, data: InputDataGeneralData(name: "Memory Report (to log)", color: theme.colors.text, type: .none, viewType: .innerItem, action: arguments.memoryReport)))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_accessibility_tree, data: InputDataGeneralData(name: "VoiceOver Accessibility Tree", color: theme.colors.text, type: .switchable(state.accessibilityTree), viewType: .innerItem, action: arguments.toggleAccessibilityTree)))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_accessibility_audit, data: InputDataGeneralData(name: "Accessibility Audit (to clipboard)", color: theme.colors.text, type: .none, viewType: .lastItem, action: arguments.accessibilityAudit)))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("RESET APP"), data: .init(viewType: .textTopItem)))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_clear_database, data: InputDataGeneralData(name: DeveloperAppReset.database.title, color: theme.colors.redUI, type: .none, viewType: .firstItem, action: {
        arguments.resetApp(.database)
    })))
    index += 1

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_clear_database_and_cache, data: InputDataGeneralData(name: DeveloperAppReset.databaseAndCache.title, color: theme.colors.redUI, type: .none, viewType: .lastItem, action: {
        arguments.resetApp(.databaseAndCache)
    })))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    return entries
}

public func DeveloperViewController(context: any AccountContextProtocol) -> InputDataController {

    let actionsDisposable = DisposableSet()

    let initialState = State(
        logToFile: false,
        legacyMenu: System.legacyMenu,
        debugWebApp: FastSettings.debugWebApp,
        useNetworkFramework: DeveloperNetworkSwitches(settings: nil).networkFrameworkTransport,
        networkEngine: .mtProtoKit,
        activeNetworkEngine: context.account.network.engineKind,
        useExperimentalDownload: DeveloperNetworkSwitches(settings: nil).downloadsV2,
        accessibilityTree: FastSettings.accessibilityTreeEnabled,
        forceRLottieBackend: DeveloperHooks.shared.forceRLottieBackend(),
        glassGroupingSecondary: SecondaryGlassGrouping.isEnabled
    )

    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((State) -> State) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    let arguments = Arguments(context: context, toggleLogs: { enabled in
        MTLogSetEnabled(enabled)
        _ = updateLoggingSettings(accountManager: context.sharedContext.accountManager, {
            $0.withUpdatedLogToFile(enabled)
        }).start()
        Logger.shared.logToConsole = false
        Logger.shared.logToFile = enabled
    }, navigateToLogs: {
        NSWorkspace.shared.activateFileViewerSelecting([ApiEnvironment.containerURL!.appendingPathComponent("logs")])
    }, addAccount: {
        verifyAlert(for: context.window, header: "Add Account", information: nil, ok: "Add", option: "Test Environment", optionIsSelected: false, successHandler: { result in
            context.sharedContext.beginNewAuth(testingEnvironment: result == .thrid)
        })
    }, toggleMenu: { value in
        _ = updateThemeInteractivetly(accountManager: context.sharedContext.accountManager, f: { settings in
            return settings.withUpdatedLegacyMenu(value)
        }).start()
        updateState { current in
            var current = current
            current.legacyMenu = value
            return current
        }
    }, toggleDebugWebApp: {
        FastSettings.toggleDebugWebApp()
        updateState { current in
            var current = current
            current.debugWebApp = FastSettings.debugWebApp
            return current
        }
    }, toggleNetwork: {
        _ = updateNetworkSettingsInteractively(postbox: context.account.postbox, network: context.account.network, { current in
            return DeveloperNetworkSwitches.toggleNetworkFrameworkTransport(current)
        }).start()
    }, selectNetworkEngine: { engine in
        if stateValue.with({ $0.networkEngine }) == engine {
            return
        }
        _ = updateNetworkEngineSettings(accountManager: context.sharedContext.accountManager, { current in
            var current = current
            current.engine = engine
            return current
        }).start()
        let network = context.account.network
        if engine != network.engineKind {
            if network.switchEngine(to: engine, reason: "developer settings") {
                updateState { current in
                    var current = current
                    current.activeNetworkEngine = network.engineKind
                    return current
                }
            } else if network.isRustEngineDisabled {
                alert(for: context.window, header: "Network Engine", info: "The server disabled the Rust engine (mtproto_engine_rust_disabled).")
            } else {
                verifyAlert(for: context.window, header: "Network Engine", information: "Restart Telegram to switch the network engine.", ok: strings().commonRestart, successHandler: { _ in
                    restartApp()
                })
            }
        }
    }, toggleDownloads: {
        _ = updateNetworkSettingsInteractively(postbox: context.account.postbox, network: context.account.network, { current in
            return DeveloperNetworkSwitches.toggleDownloadsV2(current)
        }).start()
    }, memoryReport: {
        let report = layerMemoryReport()
        Logger.shared.log("Memory", report)
        alert(for: context.window, header: "Memory Report", info: report.split(separator: "\n").prefix(18).joined(separator: "\n"))
    }, toggleAccessibilityTree: {
        FastSettings.accessibilityTreeEnabled = !FastSettings.accessibilityTreeEnabled
        TGUIKitAccessibility.isEnabled = FastSettings.accessibilityTreeEffective
        updateState { current in
            var current = current
            current.accessibilityTree = FastSettings.accessibilityTreeEnabled
            return current
        }
    }, accessibilityAudit: {
        let windows = NSApp.windows.filter { $0.isVisible }
        var lines: [String] = []
        for window in windows {
            for issue in AccessibilityAudit.audit(window) {
                lines.append("[\(window.title.isEmpty ? String(describing: type(of: window)) : window.title)] \(issue)")
            }
        }
        let report = lines.isEmpty ? "No accessibility issues in \(windows.count) window(s)." : lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        Logger.shared.log("Accessibility", report)
        alert(for: context.window, header: "Accessibility Audit", info: lines.isEmpty ? report : "\(lines.count) issue(s), copied to the clipboard.\n\n" + lines.prefix(12).joined(separator: "\n"))
    }, toggleForceRLottieBackend: {
        DeveloperHooks.shared.toggleForceRLottieBackend()
        updateState { current in
            var current = current
            current.forceRLottieBackend = DeveloperHooks.shared.forceRLottieBackend()
            return current
        }
    }, toggleGlassGrouping: {
        SecondaryGlassGrouping.setEnabled(!SecondaryGlassGrouping.isEnabled)
        updateState { current in
            var current = current
            current.glassGroupingSecondary = SecondaryGlassGrouping.isEnabled
            return current
        }
    }, resetApp: { action in
        confirmDeveloperAppReset(for: context.window, action: action) {
            guard let parameters = context.sharedContext.appEncryptionValue.decrypt(), let key = ValueBoxEncryptionParameters.Key(data: parameters.key), let salt = ValueBoxEncryptionParameters.Salt(data: parameters.salt) else {
                alert(for: context.window, header: "Reset App", info: "Could not preserve your login. The database has not been cleared.") //TODOLANG
                return
            }
            let store = DeveloperAppResetBackupStore(accountBasePath: context.account.basePath, accountId: context.account.id, encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt))
            actionsDisposable.add((accountBackupData(postbox: context.account.postbox)
            |> mapToSignal { backupData in
                return saveDeveloperAppResetBackup(backupData, store: store, accountManager: context.sharedContext.accountManager)
            }
            |> deliverOnMainQueue).start(next: { saved in
                guard saved else {
                    alert(for: context.window, header: "Reset App", info: "Could not preserve your login. The database has not been cleared.")
                    return
                }
                do {
                    try action.performAndRelaunch(accountBasePath: context.account.basePath, backupStore: store, process: appRelaunchProcess())
                } catch {
                    alert(for: context.window, header: "Reset App", info: "Could not prepare to restart Telegram. Please try again.")
                }
            }))
        }
    })

    let networkSignal = context.account.postbox.preferencesView(keys: [PreferencesKeys.networkSettings]) |> map { view -> NetworkSettings in
        return view.values[PreferencesKeys.networkSettings]?.get(NetworkSettings.self) ?? .defaultSettings
    }

    actionsDisposable.add(combineLatest(queue: .mainQueue(),
        context.sharedContext.accountManager.sharedData(keys: [SharedDataKeys.loggingSettings, SharedDataKeys.networkEngineSettings]),
        networkSignal
    ).start(next: { sharedData, networkSettings in
        let logging = sharedData.entries[SharedDataKeys.loggingSettings]?.get(LoggingSettings.self) ?? LoggingSettings.defaultSettings
        let networkEngine = sharedData.entries[SharedDataKeys.networkEngineSettings]?.get(NetworkEngineSettings.self) ?? NetworkEngineSettings.defaultSettings
        let networkSwitches = DeveloperNetworkSwitches(settings: networkSettings)
        updateState { current in
            var current = current
            current.logToFile = logging.logToFile
            current.useNetworkFramework = networkSwitches.networkFrameworkTransport
            current.networkEngine = networkEngine.engine
            current.useExperimentalDownload = networkSwitches.downloadsV2
            return current
        }
    }))

    let signal = statePromise.get() |> deliverOnPrepareQueue |> map { state in
        return InputDataSignalValue(entries: entries(state, arguments: arguments))
    }

    let controller = InputDataController(dataSignal: signal, title: "Developer", hasDone: false)

    controller.onDeinit = {
        actionsDisposable.dispose()
    }

    return controller
}

func confirmDeveloperAppReset(for window: Window, action: DeveloperAppReset, reset: @escaping () -> Void) {
    let presentation = theme.withUpdatedColors(theme.colors.withAccentColor(.init(theme.colors.redUI)))
    verifyAlert(for: window, header: action.title, information: "All secret chats will be lost.", ok: DeveloperAppReset.database.title, successHandler: { _ in
        reset()
    }, presentation: presentation)
}


private func layerMemoryReport() -> String {
    struct Entry {
        var count: Int = 0
        var bytes: Int = 0
    }
    var byOwner: [String: Entry] = [:]
    var layerCount = 0
    var totalBytes = 0

    func visit(_ layer: CALayer) {
        layerCount += 1
        if let contents = layer.contents {
            let object = contents as AnyObject
            let bytes: Int
            let kind: String
            if CFGetTypeID(object) == CGImage.typeID {
                let image = object as! CGImage
                bytes = image.bytesPerRow * image.height
                kind = "image"
            } else {
                let scale = layer.contentsScale
                bytes = Int(layer.bounds.width * scale) * Int(layer.bounds.height * scale) * 4
                kind = String(describing: type(of: object))
            }
            if bytes > 0 {
                let owner = (layer.delegate as? NSView).map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
                let key = "\(owner) <\(kind)>"
                var entry = byOwner[key] ?? Entry()
                entry.count += 1
                entry.bytes += bytes
                byOwner[key] = entry
                totalBytes += bytes
            }
        }
        for sublayer in layer.sublayers ?? [] {
            visit(sublayer)
        }
    }
    for window in NSApp.windows {
        if let layer = window.contentView?.layer {
            visit(layer)
        }
    }

    var lines: [String] = []
    var vmInfo = task_vm_info_data_t()
    var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let vmResult = withUnsafeMutablePointer(to: &vmInfo) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
        }
    }
    if vmResult == KERN_SUCCESS {
        lines.append(String(format: "footprint %.1f MB", Double(vmInfo.phys_footprint) / 1048576))
    }
    var mallocStats = malloc_statistics_t()
    malloc_zone_statistics(nil, &mallocStats)
    lines.append(String(format: "malloc in use %.1f MB, allocated %.1f MB", Double(mallocStats.size_in_use) / 1048576, Double(mallocStats.size_allocated) / 1048576))
    lines.append(String(format: "layer contents %.1f MB in %d layers", Double(totalBytes) / 1048576, layerCount))
    for (key, entry) in byOwner.sorted(by: { $0.value.bytes > $1.value.bytes }).prefix(40) {
        lines.append(String(format: "%7.2f MB x%-4d %@", Double(entry.bytes) / 1048576, entry.count, key))
    }
    return lines.joined(separator: "\n")
}
