import Cocoa
import TGUIKit
import Postbox
import TelegramCore
import SwiftSignalKit
import ChatModeTypes
import ChatHistoryModel
import TelegramMediaUtils
import TelegramCallsCore
import ShareUI
import CrashReports
import ApiCredentials
import NanogramLogExport

let nanogramCrashReportStore = CrashReportStore(handledKey: "crashReports.handledUntil." + ApiEnvironment.prefix)

private final class NanogramLogShareObject: ShareObject {
    private let files: [URL]
    private let sent: @MainActor @Sendable (Bool) -> Void

    init(_ context: AccountContext, files: [URL], sent: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.files = files
        self.sent = sent
        super.init(context)
    }

    override var messagesCount: Int {
        return self.files.count
    }

    override func possibilityPerformTo(_ peer: Peer) -> Bool {
        return !self.excludePeerIds.contains(peer.id) && peer.id.namespace != Namespaces.Peer.SecretChat && peer.canSendMessage(false)
    }

    override func perform(to peerIds: [PeerId], threadId: Int64?, comment: ChatTextInputState? = nil, sendPaidMessageStars: [PeerId: StarsAmount] = [:]) -> Signal<Never, String> {
        let context = self.context
        let threadIds = self.threadIds
        let silent = self.withoutSound
        let atDate = self.scheduleDate
        let containers = self.files.map { MediaSenderContainer(path: $0.path, isFile: true) }
        let sent = self.sent
        let signals = peerIds.map { peerId -> Signal<[MessageId?], NoError> in
            let threadId = threadIds[peerId] ?? threadId
            let stars = sendPaidMessageStars[peerId]
            let send = Sender.enqueue(media: containers, context: context, peerId: peerId, replyId: nil, threadId: threadId, silent: silent, atDate: atDate, sendPaidMessageStars: stars)
            if let comment, !comment.inputText.isEmpty {
                return Sender.enqueue(input: comment, context: context, peerId: peerId, replyId: nil, threadId: threadId, silent: silent, atDate: atDate, sendPaidMessageStars: stars) |> take(1) |> mapToSignal { _ in send }
            }
            return send
        }
        return combineLatest(signals)
        |> take(1)
        |> deliverOnMainQueue
        |> beforeNext { results in
            let delivered = results.allSatisfy { ids in ids.contains(where: { $0 != nil }) }
            DispatchQueue.main.async {
                sent(delivered)
            }
        }
        |> ignoreValues
        |> castError(String.self)
    }
}

private final class NanogramLogExportProgress: @unchecked Sendable {
    let done = ValuePromise<Bool>(false, ignoreRepeated: true)
}

@MainActor
private func currentLogExportContext() -> AccountContext? {
    guard let context = appDelegate?.currentContext, !context.isSupport else {
        return nil
    }
    return context
}

@MainActor
private func nanogramLogCollector(_ kind: NanogramLogExportKind) -> NanogramLogCollector {
    switch kind {
    case .appLogs:
        let logs = ApiEnvironment.containerURL?.appendingPathComponent("logs", isDirectory: true)
        return {
            return logs.map { [$0] } ?? []
        }
    case .callLogs:
        guard let account = currentLogExportContext()?.account else {
            return { [] }
        }
        let directories = [callLogsPath(account: account), groupCallLogsPath(account: account)].map { URL(fileURLWithPath: $0, isDirectory: true) }
        return {
            return directories
        }
    case .crashReports:
        return {
            return nanogramCrashReportStore.allReports().map { $0.url }
        }
    case .metricKit:
        return {
            return MetricReportStore.shared.reports().map { URL(fileURLWithPath: $0.path) }
        }
    }
}

func installNanogramLogExportHooks() {
    NanogramLogExportHooks.install(NanogramLogExportHooks(collect: { kind in
        return nanogramLogCollector(kind)
    }, canSendInApp: {
        return currentLogExportContext() != nil
    }, sendToChat: { files, _, completion in
        guard let context = currentLogExportContext() else {
            completion(false)
            return
        }
        context.window.makeKeyAndOrderFront(nil)
        showModal(with: ShareModalController(NanogramLogShareObject(context, files: files, sent: completion)), for: context.window)
    }, showProgress: { window in
        guard let window = window as? Window else {
            return {}
        }
        let progress = NanogramLogExportProgress()
        _ = showModalProgress(signal: progress.done.get() |> filter { $0 } |> take(1), for: window).start()
        return {
            progress.done.set(true)
        }
    }, showMessage: { window, text in
        if let window = window as? Window {
            showModalText(for: window, text: text)
        } else {
            NanogramLogExportHooks.standalone.showMessage(window, text)
        }
    }))
}
