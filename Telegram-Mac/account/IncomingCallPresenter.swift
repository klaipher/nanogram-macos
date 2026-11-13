import Cocoa
import SwiftSignalKit
import Postbox
import TGUIKit
import TelegramCore
import NanogramRuntime

// Main-thread confined: begin and end assert it, respond hops to the main queue.
final class IncomingCallPresenter: @unchecked Sendable {
    static let shared = IncomingCallPresenter()

    private struct Entry {
        let callId: String
        let attentionRequest: Int?
        let disposable: Disposable
    }

    private var entries: [CallSessionInternalId: Entry] = [:]
    weak var sharedContext: SharedAccountContext?

    func begin(session: PCallSession, account: Account, callerName: String?) {
        assertOnMainThread()
        let id = session.internalId
        if entries[id] != nil {
            return
        }
        let notifications = UNUserNotifications.current
        let hidesCaller = IncomingCallPolicy.hidesCaller(isLocked: notifications?.isLockedForCalls ?? false, previewsEnabled: true)
        sharedContext?.peerCall?.hidesIncomingCaller = hidesCaller

        let callId = id.uuidString
        let attention: Int? = MainActor.assumeIsolated {
            NSApp.isActive ? nil : NSApp.requestUserAttention(.criticalRequest)
        }
        let info = IncomingCallNotificationInfo(callId: callId, accountId: account.id.int64, isVideo: session.isVideo)
        let title = IncomingCallPolicy.displayTitle(callerName: callerName, hidesCaller: hidesCaller, appName: appName)
        notifications?.postIncomingCall(info, title: title, body: strings().callStatusCalling)

        let disposable = combineLatest(session.state, session.canBeRemoved)
        |> deliverOnMainQueue
        |> filter { state, canBeRemoved in
            if canBeRemoved {
                return true
            }
            if case .ringing = state.state {
                return false
            }
            return true
        }
        |> take(1)
        let handle = disposable.start(next: { [weak self] _ in
            self?.end(id)
        })
        entries[id] = Entry(callId: callId, attentionRequest: attention, disposable: handle)
    }

    func end(_ id: CallSessionInternalId) {
        assertOnMainThread()
        guard let entry = entries.removeValue(forKey: id) else {
            return
        }
        entry.disposable.dispose()
        if let attention = entry.attentionRequest {
            MainActor.assumeIsolated {
                NSApp.cancelUserAttentionRequest(attention)
            }
        }
        UNUserNotifications.current?.removeIncomingCall(callId: entry.callId)
        CallDiagnostics.log("ring: presentation for call \(entry.callId) ended")
    }

    func respond(to target: IncomingCallNotificationTarget) {
        Queue.mainQueue().async { [weak self] in
            guard let sharedContext = self?.sharedContext, let session = sharedContext.p2pCall, session.internalId.uuidString == target.callId else {
                CallDiagnostics.log("ring: notification action for call \(target.callId) found no live session")
                UNUserNotifications.current?.removeIncomingCall(callId: target.callId)
                return
            }
            switch target.action {
            case .open:
                let window = sharedContext.peerCall?.window
                MainActor.assumeIsolated {
                    NSApp.activate(ignoringOtherApps: true)
                    window?.makeKeyAndOrderFront(nil)
                }
            case .accept:
                CallDiagnostics.log("ring: call \(target.callId) accepted from the notification")
                session.acceptCallSession()
                let window = sharedContext.peerCall?.window
                MainActor.assumeIsolated {
                    NSApp.activate(ignoringOtherApps: true)
                    window?.makeKeyAndOrderFront(nil)
                }
            case .decline:
                CallDiagnostics.log("ring: call \(target.callId) declined from the notification")
                session.setToRemovableState()
                _ = session.hangUpCurrentCall().start()
            }
        }
    }
}
