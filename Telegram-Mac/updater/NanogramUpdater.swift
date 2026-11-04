#if NANOGRAM && !NANOGRAM_MAS

import Cocoa
import TGUIKit
import TelegramCore
import Postbox
@preconcurrency import SwiftSignalKit
import Sparkle
import CrashRecoveryUI
import NanogramKit

// Direct edition updater on Sparkle 2: replaces upstream's AppUpdateViewController.swift (Sparkle 1 private
// driver API, compiled out under NANOGRAM) with the same app-facing API, so MainViewController, SettingsHooks,
// AppDelegate and crash recovery keep working. Feed and EdDSA key come from Info.plist (SUFeedURL, SUPublicEDKey).

extension SUAppcastItem {
    var isCritical: Bool {
        return isCriticalUpdate
    }

    var updateText: String {
        return UpdateNotes.plainText(from: itemDescription)
    }

    var versionTitle: String {
        return "Version \(displayVersionString) (\(versionString))"
    }
}

enum AppUpdateLoadingState: Equatable {
    case nonInited
    case initializing
    case loading(item: SUAppcastItem, current: Int, total: Int)
    case hasUpdate(SUAppcastItem)
    case readyToInstall(SUAppcastItem)
    case uptodate
    case unarchiving(SUAppcastItem)
    case installing
    case failed(NSError)
}

struct AppUpdateState: Equatable {
    let items: [SUAppcastItem]
    let loadingState: AppUpdateLoadingState
}

enum UpdaterSource: Equatable {
    static func == (lhs: UpdaterSource, rhs: UpdaterSource) -> Bool {
        switch (lhs, rhs) {
        case let (.external(l), .external(r)):
            return l === r
        case let (.internal(l), .internal(r)):
            return l === r
        default:
            return false
        }
    }

    case external(context: AccountContext?)
    case `internal`(context: AccountContext)
}

nonisolated(unsafe) private let statePromise = ValuePromise(AppUpdateState(items: [], loadingState: .nonInited), ignoreRepeated: true)

var appUpdateStateSignal: Signal<AppUpdateState, NoError> {
    return statePromise.get()
}

private func loadingState(_ phase: UpdateFlow<SUAppcastItem>.Phase) -> AppUpdateLoadingState {
    switch phase {
    case .idle:
        return .nonInited
    case .checking:
        return .initializing
    case let .found(item):
        return .hasUpdate(item)
    case let .downloading(item, received, expected):
        return .loading(item: item, current: Int(clamping: received), total: Int(clamping: expected))
    case let .extracting(item):
        return .unarchiving(item)
    case let .readyToInstall(item):
        return .readyToInstall(item)
    case .installing:
        return .installing
    case .upToDate:
        return .uptodate
    case let .failed(message):
        return .failed(NSError(domain: message, code: 0, userInfo: [NSLocalizedDescriptionKey: message]))
    }
}

@MainActor
private final class NanogramUpdateDriver: NSObject, SPUUserDriver {
    private var flow = UpdateFlow<SUAppcastItem>()
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var retryTermination: (() -> Void)?
    private(set) var phase: UpdateFlow<SUAppcastItem>.Phase = .idle

    private func apply(_ event: UpdateFlow<SUAppcastItem>.Event) {
        flow.apply(event)
        phase = flow.phase
        statePromise.set(AppUpdateState(items: flow.item.map { [$0] } ?? [], loadingState: loadingState(flow.phase)))
    }

    func download() {
        let reply = foundReply
        foundReply = nil
        reply?(.install)
    }

    func install() {
        if let reply = readyReply {
            readyReply = nil
            reply(.install)
        } else {
            retryTermination?()
        }
    }

    func installOnQuit() {
        let reply = readyReply
        readyReply = nil
        reply?(.dismiss)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        apply(.checkStarted)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if appcastItem.isInformationOnlyUpdate {
            reply(.dismiss)
            apply(.notFound)
            return
        }
        switch state.stage {
        case .installing:
            apply(.found(appcastItem))
            apply(.ready)
            readyReply = reply
        case .downloaded:
            apply(.found(appcastItem))
            reply(.install)
        default:
            apply(.found(appcastItem))
            foundReply = reply
            download()
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        apply(.notFound)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        foundReply = nil
        readyReply = nil
        apply(.failed(error.localizedDescription))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        apply(.downloadStarted)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        apply(.expectedLength(expectedContentLength))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        apply(.received(length))
    }

    func showDownloadDidStartExtractingUpdate() {
        apply(.extractionStarted)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyReply = reply
        apply(.ready)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        retryTermination = retryTerminatingApplication
        apply(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        foundReply = nil
        apply(.dismissed)
    }
}

@MainActor
private final class NanogramUpdater {
    static let shared = NanogramUpdater()

    let driver = NanogramUpdateDriver()
    private lazy var updater = SPUUpdater(hostBundle: Bundle.main, applicationBundle: Bundle.main, userDriver: driver, delegate: nil)
    private var started = false

    private func start() -> Bool {
        if !started {
            do {
                try updater.start()
                updater.automaticallyChecksForUpdates = true
                updater.automaticallyDownloadsUpdates = false
                updater.updateCheckInterval = UpdateCheckSchedule.interval
                started = true
            } catch {
                statePromise.set(AppUpdateState(items: [], loadingState: .failed(error as NSError)))
            }
        }
        return started
    }

    func check() {
        guard start() else {
            return
        }
        switch driver.phase {
        case .downloading, .extracting, .installing:
            return
        default:
            if updater.canCheckForUpdates {
                updater.checkForUpdatesInBackground()
            }
        }
    }

    func checkInBackground() {
        guard start() else {
            return
        }
        if UpdateCheckSchedule.isBackgroundCheckDue(lastCheck: updater.lastUpdateCheckDate, now: Date()) {
            check()
        }
    }

    func checkOnOpeningUpdateScreen() {
        switch driver.phase {
        case .downloading, .extracting, .readyToInstall, .installing:
            return
        default:
            checkByUser()
        }
    }

    func checkByUser() {
        guard start() else {
            return
        }
        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }
    }
}

// Every caller of the app-facing functions (UI actions, AppDelegate, signals delivered on the main queue) runs
// on the main thread, where Sparkle's updater and user driver live.
@discardableResult
private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T? {
    guard Thread.isMainThread else {
        assertionFailure("the updater is driven from the main thread only")
        return nil
    }
    return MainActor.assumeIsolated(body)
}

func setAppUpdaterBaseDomain(_ domain: String?) {}

func updater_resetWithUpdaterSource(_ source: UpdaterSource, force: Bool = true) {
    if force {
        onMain { NanogramUpdater.shared.checkInBackground() }
    }
}

func updateApplication(sharedContext: SharedAccountContext) {
    let readyText: String?? = onMain {
        let updater = NanogramUpdater.shared
        guard case let .readyToInstall(item) = updater.driver.phase else {
            updater.check()
            return nil
        }
        return "Nanogram was updated to \(item.versionTitle.lowercased())\n\n" + item.updateText
    }
    guard let text = readyText ?? nil else {
        return
    }
    _ = (sharedContext.activeAccountsWithInfo |> take(1) |> mapToSignal { _, accounts -> Signal<Never, NoError> in
        return combineLatest(accounts.map { addAppUpdateText($0.account.postbox, applyText: text) }) |> ignoreValues
    } |> deliverOnMainQueue).start(completed: {
        onMain { NanogramUpdater.shared.driver.install() }
    })
}

func updateAppIfNeeded() {
    onMain { NanogramUpdater.shared.driver.installOnQuit() }
}

func crashRecoveryUpdater() -> CrashRecoveryUpdater {
    let state: Signal<CrashRecoveryUpdateState, NoError> = appUpdateStateSignal |> map { state in
        switch state.loadingState {
        case .nonInited, .initializing:
            return .checking
        case let .loading(item, current, total):
            return .downloading(version: item.displayVersionString, current: current, total: total)
        case let .hasUpdate(item):
            return .downloading(version: item.displayVersionString, current: 0, total: Int(clamping: item.contentLength))
        case let .unarchiving(item):
            return .preparing(version: item.displayVersionString)
        case let .readyToInstall(item):
            return .readyToInstall(version: item.displayVersionString)
        case .installing:
            return .installing
        case .uptodate:
            return .upToDate
        case .failed:
            return .failed
        }
    }
    return CrashRecoveryUpdater(state: state, check: {
        onMain { NanogramUpdater.shared.checkByUser() }
    }, install: {
        onMain { NanogramUpdater.shared.driver.install() }
    })
}

private var _id_initializing: InputDataIdentifier { InputDataIdentifier("_id_initializing") }
private var _id_downloading: InputDataIdentifier { InputDataIdentifier("_id_downloading") }
private var _id_download_update: InputDataIdentifier { InputDataIdentifier("_id_download_update") }
private var _id_install_update: InputDataIdentifier { InputDataIdentifier("_id_install_update") }
private var _id_check_for_updates: InputDataIdentifier { InputDataIdentifier("_id_check_for_updates") }
private var _id_unarchiving: InputDataIdentifier { InputDataIdentifier("_id_unarchiving") }

private func appUpdateEntries(state: AppUpdateState) -> [InputDataEntry] {
    var entries: [InputDataEntry] = []
    var sectionId: Int32 = 0
    var index: Int32 = 0

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    func row(_ identifier: InputDataIdentifier, _ name: String, _ color: NSColor) {
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: identifier, data: InputDataGeneralData(name: name, color: color, icon: nil, type: .none, viewType: .singleItem, action: nil)))
        index += 1
    }

    var currentItem: SUAppcastItem?
    switch state.loadingState {
    case let .failed(error):
        row(_id_check_for_updates, strings().appUpdateCheckForUpdates, theme.colors.accent)
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain(error.localizedDescription), data: InputDataGeneralTextData(color: theme.colors.redUI, detectBold: false, viewType: .textBottomItem)))
        index += 1
    case let .hasUpdate(item):
        row(_id_download_update, strings().appUpdateDownloadUpdate, theme.colors.accent)
        currentItem = item
    case .initializing, .nonInited:
        row(_id_initializing, strings().appUpdateRetrievingInfo, theme.colors.grayText)
    case let .loading(item, current, total):
        row(_id_downloading, "\(strings().appUpdateDownloading)  \(String.prettySized(with: current, forceDecimal: true) + " / " + String.prettySized(with: total))", theme.colors.grayText)
        currentItem = item
    case .uptodate:
        row(_id_check_for_updates, strings().appUpdateCheckForUpdates, theme.colors.accent)
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain(strings().appUpdateUptodate), data: InputDataGeneralTextData(detectBold: false, viewType: .textBottomItem)))
        index += 1
    case let .unarchiving(item):
        row(_id_unarchiving, strings().appUpdateUnarchiving, theme.colors.grayText)
        currentItem = item
    case let .readyToInstall(item):
        row(_id_install_update, strings().updateUpdateTelegram, theme.colors.accent)
        currentItem = item
    case .installing:
        break
    }

    if let item = currentItem {
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain(strings().appUpdateNewestAvailable), data: InputDataGeneralTextData(detectBold: false, viewType: .textTopItem)))
        index += 1
        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1
        let text = "**" + item.versionTitle + "**" + "\n" + item.updateText
        entries.append(InputDataEntry.custom(sectionId: sectionId, index: index, value: .none, identifier: InputDataIdentifier("_id_update_\(item.versionString)"), equatable: nil, comparable: nil, item: { initialSize, stableId in
            return GeneralTextRowItem(initialSize, stableId: stableId, text: text, textColor: theme.colors.listGrayText, fontSize: 13, isTextSelectable: true, viewType: .textTopItem)
        }))
        index += 1
    }

    entries.append(.sectionId(sectionId, type: .normal))
    return entries
}

func AppUpdateViewController() -> InputDataController {
    onMain { NanogramUpdater.shared.checkOnOpeningUpdateScreen() }
    let signal: Signal<InputDataSignalValue, NoError> = statePromise.get() |> deliverOnResourceQueue |> map { value in
        return InputDataSignalValue(entries: appUpdateEntries(state: value))
    }
    return InputDataController(dataSignal: signal, title: strings().appUpdateTitle, validateData: { data in
        let download = data[_id_download_update] != nil
        let check = data[_id_check_for_updates] != nil
        let install = data[_id_install_update] != nil
        onMain {
            let updater = NanogramUpdater.shared
            if download {
                updater.driver.download()
            }
            if check {
                updater.checkByUser()
            }
            if install {
                updater.driver.install()
            }
        }
        return .none
    }, afterDisappear: {}, hasDone: false, identifier: "app_update")
}

#endif
