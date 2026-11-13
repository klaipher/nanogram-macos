import Cocoa
import SwiftSignalKit
import Postbox
import TelegramCore
import NanogramRuntime



private struct AccountTasks {
    let stateSynchronization: Bool
    let importantTasks: AccountRunningImportantTasks
    let backgroundDownloads: Bool
    let backgroundAudio: Bool
    let activeCalls: Bool
    let userInterfaceInUse: Bool
    
    var isEmpty: Bool {
        if self.stateSynchronization {
            return false
        }
        if !self.importantTasks.isEmpty {
            return false
        }
        if self.backgroundDownloads {
            return false
        }
        if self.backgroundAudio {
            return false
        }
        if self.activeCalls {
            return false
        }
        if self.userInterfaceInUse {
            return false
        }
        return true
    }
}



class SharedWakeupManager {
    private var accountsAndTasks: [(Account, Bool, AccountTasks)] = []
    private let sharedContext: SharedAccountContext
    
    private var stateManagmentReseted: Set<AccountRecordId> = Set()
    private var ringingStatesDisposables: [AccountRecordId: Disposable] = [:]
    private var ringLedgers: [AccountRecordId: IncomingCallRingLedger<CallSessionInternalId>] = [:]
    private var inForeground: Bool = false
    private let appliedFlags = AccountWakeupFlagsCache<AccountRecordId>()

    private var sleepState = SleepState() {
        didSet {
            if sleepState.isSleeping != oldValue.isSleeping {
                onSleepValueUpdated?(sleepState.isSleeping)
            }
        }
    }

    var isSleeping: Bool {
        return sleepState.isSleeping
    }
    
    var onSleepValueUpdated:((Bool)->Void)?
    
    init(sharedContext: SharedAccountContext, inForeground: Signal<Bool, NoError>) {
        self.sharedContext = sharedContext
        IncomingCallPresenter.shared.sharedContext = sharedContext
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveSystemSleepNote(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveSystemWakeNote(_:)), name: NSWorkspace.didWakeNotification, object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveScreensWakeNote(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveScreensSleepNote(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)

        
        _ = (inForeground |> distinctUntilChanged |> deliverOnMainQueue).start(next: { value in
                self.inForeground = value
                self.checkTasks()
            })

       
        let signal = (sharedContext.activeAccounts |> map { ($0.0, $0.1.map { ($0.0, $0.1) }) } |> mapToSignal { primary, accounts -> Signal<[(Account, Bool, AccountTasks)], NoError> in
            
            let result: [Signal<(Account, Bool, AccountTasks), NoError>] = accounts.map { (_, account) -> Signal<(Account, Bool, AccountTasks), NoError> in
                return account.importantTasksRunning |> map { importantTasks in
                    return (account, primary?.id == account.id, AccountTasks(stateSynchronization: false, importantTasks: importantTasks, backgroundDownloads: false, backgroundAudio: false, activeCalls: false, userInterfaceInUse: false))
                }
            }
            
            return combineLatest(result)
            
        } |> deliverOnMainQueue)

        
        _ = signal.start(next: { accountsAndTasks in
            self.accountsAndTasks = accountsAndTasks
            self.updateRindingsStatuses(self.accountsAndTasks.map( { $0.0 } ))
            self.checkTasks()
        })
    }
    
    private func checkTasks() {
        updateAccounts()
    }
    
    @objc func receiveSystemSleepNote(_ notification: Notification) {
        sleepState.systemWillSleep()
        updateAccounts()
    }
    
    @objc func receiveSystemWakeNote(_ notification: Notification) {
        sleepState.systemDidWake()
        updateAccounts()
    }

    @objc func receiveScreensSleepNote(_ notification: Notification) {
        sleepState.screensDidSleep()
    }

    @objc func receiveScreensWakeNote(_ notification: Notification) {
        sleepState.screensDidWake()
    }

    private func updateRindingsStatuses(_ accounts:[Account]) {
        
        let activeIds = Set(accounts.map { $0.id })
        for (id, disposable) in self.ringingStatesDisposables where !activeIds.contains(id) {
            disposable.dispose()
            self.ringingStatesDisposables.removeValue(forKey: id)
            self.ringLedgers.removeValue(forKey: id)
        }
        let accountManager = sharedContext.accountManager
        for account in accounts {
            if self.ringingStatesDisposables[account.id] == nil {
                
                let ringing = account.callSessionManager.ringingStates()
                |> deliverOnMainQueue
                |> map { [weak self] states -> [CallSessionRingingState] in
                    self?.ringLedgers[account.id, default: IncomingCallRingLedger()].prune(keeping: Set(states.map { $0.id }))
                    return states
                }
                let isUpdating = account.stateManager.isUpdating
                let combine = ringing
                |> map { $0.first }
                |> distinctUntilChanged(isEqual: { $0?.id == $1?.id })
                |> mapToSignal { state -> Signal<(CallSessionRingingState, PCallSession.InitialData)?, NoError> in
                    guard let state = state else {
                        return .single(nil)
                    }
                    CallDiagnostics.log("ring: state received for call \(state.id)")
                    let graceElapsed: Signal<Bool, NoError> = .single(false) |> then(.single(true) |> delay(IncomingCallPolicy.ringGateGrace, queue: Queue.mainQueue()))
                    let ready = combineLatest(isUpdating, graceElapsed)
                    |> filter { IncomingCallPolicy.isRingReady(isUpdating: $0, graceElapsed: $1) }
                    |> take(1)
                    return ready |> mapToSignal { _ -> Signal<(CallSessionRingingState, PCallSession.InitialData)?, NoError> in
                        return getPrivateCallSessionData(account, accountManager: accountManager, peerId: state.peerId)
                        |> timeout(IncomingCallPolicy.sessionDataTimeout, queue: Queue.mainQueue(), alternate: .single(PCallSession.InitialData.fallback))
                        |> map { data -> (CallSessionRingingState, PCallSession.InitialData)? in
                            return (state, data)
                        }
                    }
                }
                |> mapToSignal { value -> Signal<(CallSessionRingingState, PCallSession.InitialData), NoError> in
                    if let value = value {
                        return .single(value)
                    }
                    return .complete()
                }
                |> deliverOnMainQueue
                self.ringingStatesDisposables[account.id] = combine.start(next: { [weak self] data in
                    guard let self else {
                        return
                    }
                    let state = data.0
                    let initialData = data.1
                    
                    let active: IncomingCallActiveCall<CallSessionInternalId>?
                    if let p2p = self.sharedContext.p2pCall {
                        active = .p2p(id: p2p.internalId, isEnded: p2p.isEnded)
                    } else if self.sharedContext.hasActiveCall {
                        active = .group
                    } else {
                        active = nil
                    }
                    
                    let action = self.ringLedgers[account.id, default: IncomingCallRingLedger()].decide(ringId: state.id, active: active)
                    switch action {
                    case .ignore:
                        return
                    case .rejectBusy:
                        CallDiagnostics.log("ring: call \(state.id) answered busy, the active call is live")
                        account.callSessionManager.drop(internalId: state.id, reason: .busy, debugLog: .single(nil))
                    case .present, .replaceEndedSession:
                        if action == .replaceEndedSession {
                            CallDiagnostics.log("ring: replacing the ended session with call \(state.id)")
                            self.sharedContext.dropCrossCall()
                        }
                        
                        var otherParticipants: [EnginePeer] = state.otherParticipants
                        
                        #if DEBUG
                        let fake = TelegramUser(id: PeerId(1), accessHash: nil, firstName: strings().appearanceSettingsChatPreviewUserName1, lastName: "", username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
                        
                        otherParticipants = [.init(fake)]
                        
                        #endif
                        
                        if state.peerId != account.peerId {
                            let session = PCallSession(sharedContext: self.sharedContext, account: account, isOutgoing: false, incomingConferenceSource: state.conferenceSource, incomingParticipants: otherParticipants, peerId: state.peerId, id: state.id, initialState: nil, startWithVideo: state.isVideo, isVideoPossible: state.isVideoPossible, data: initialData)
                            CallDiagnostics.log("ring: session created for call \(state.id)")
                            showCallWindow(session)
                            IncomingCallPresenter.shared.begin(session: session, account: account, callerName: initialData.peer?.displayTitle)
                        }
                    }
                })
            }
            
        }
        
    }
    
    private func flags(primary: Bool, tasks: AccountTasks, account: Account) -> AccountWakeupFlags {
        let based = appDelegate?.supportAccountContextValue?.find(account.id)
        return AccountWakeupFlags(serviceTaskMaster: sleepState.keepsNetwork, keepWorkerConnections: tasks.backgroundAudio, keepOnlinePresence: (primary || based != nil) && self.inForeground, keepBackgroundDownloads: tasks.backgroundDownloads)
    }

    private func updateAccounts() {
        appliedFlags.keep(only: Set(self.accountsAndTasks.map { $0.0.id }))
        for (account, primary, tasks) in self.accountsAndTasks {
            let flags = self.flags(primary: primary, tasks: tasks, account: account)
            for flag in appliedFlags.changes(for: account.id, flags) {
                switch flag {
                case .serviceTaskMaster:
                    account.shouldBeServiceTaskMaster.set(.single(flags.serviceTaskMaster ? .always : .never))
                case .keepWorkerConnections:
                    account.shouldExplicitelyKeepWorkerConnections.set(.single(flags.keepWorkerConnections))
                case .keepOnlinePresence:
                    account.shouldKeepOnlinePresence.set(.single(flags.keepOnlinePresence))
                case .keepBackgroundDownloads:
                    account.shouldKeepBackgroundDownloadConnections.set(.single(flags.keepBackgroundDownloads))
                }
            }
            
            if !stateManagmentReseted.contains(account.id) {
                account.resetStateManagement()
                stateManagmentReseted.insert(account.id)
            }
        }
    }

}
