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
import NanogramDebug
import NanogramDebugUI

let nanogramCrashReportStore = CrashReportStore(handledKey: "crashReports.handledUntil." + ApiEnvironment.prefix)

func nanogramLogExportKindIsAvailable(_ kind: NanogramLogExportKind) -> Bool {
    switch kind {
    case .crashReports:
        return nanogramCrashReportStore.isAvailable
    case .appLogs, .callLogs, .metricKit, .fullReport:
        return true
    }
}

private final class NanogramLogShareObject: ShareObject {
    private let files: [URL]
    private let queued: ([MessageId]) -> Void

    init(_ context: AccountContext, files: [URL], queued: @escaping ([MessageId]) -> Void) {
        self.files = files
        self.queued = queued
        super.init(context)
    }

    override var messagesCount: Int {
        return self.files.count
    }

    override var successText: String {
        return "Sending…" //TODOLANG
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
        let queued = self.queued
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
            queued(results.flatMap { ids in ids.compactMap { $0 } })
        }
        |> ignoreValues
        |> castError(String.self)
    }
}

private final class NanogramLogChatSend {
    private let completion: NanogramLogChatSendCompletion
    private let disposable = MetaDisposable()
    private var tracking = false
    private var reported = false

    init(completion: @escaping NanogramLogChatSendCompletion) {
        self.completion = completion
    }

    func pickerClosed(sent: Bool) {
        if !sent && !self.tracking {
            self.report(.cancelled)
        }
    }

    func track(_ ids: [MessageId], context: AccountContext) {
        guard !self.reported, !self.tracking else {
            return
        }
        self.tracking = true
        if ids.isEmpty {
            self.report(.failed)
            return
        }
        let items = ids.map { TelegramEngine.EngineData.Item.Messages.Message(id: $0) }
        self.disposable.set((context.engine.data.subscribe(EngineDataList(items))
        |> map { messages -> NanogramLogChatSendResult? in
            return nanogramLogChatUploadResult(messages.map { message -> NanogramLogChatUploadState in
                guard let message = message else {
                    return .sent
                }
                if message.flags.contains(.Failed) {
                    return .failed
                }
                return message.flags.contains(.Unsent) ? .pending : .sent
            })
        }
        |> filter { $0 != nil }
        |> take(1)
        |> deliverOnMainQueue).start(next: { result in
            if let result = result {
                self.report(result)
            }
        }))
    }

    private func report(_ result: NanogramLogChatSendResult) {
        guard !self.reported else {
            return
        }
        self.reported = true
        self.disposable.dispose()
        let completion = self.completion
        DispatchQueue.main.async {
            completion(result)
        }
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
    case .fullReport:
        let logs = ApiEnvironment.containerURL?.appendingPathComponent("logs", isDirectory: true)
        let callDirectories = currentLogExportContext().map { context in
            return [callLogsPath(account: context.account), groupCallLogsPath(account: context.account)].map { URL(fileURLWithPath: $0, isDirectory: true) }
        } ?? []
        let settings = NanogramDebugSettings.shared
        let settingsLines = NanogramReport.settingsLines(settings.options.map { option in
            switch option.kind {
            case .toggle:
                return (option.id, settings.bool(option.id) ? "on" : "off")
            case .choice:
                return (option.id, settings.choice(option.id) ?? "default")
            }
        })
        return {
            let sections = [
                NanogramReportSection(folder: "call-logs", title: "Call logs", sources: callDirectories), //TODOLANG
                NanogramReportSection(folder: "crash-reports", title: "Crash and hang reports", sources: nanogramCrashReportStore.allReports().map { $0.url }), //TODOLANG
                NanogramReportSection(folder: "metrickit", title: "MetricKit reports", sources: MetricReportStore.shared.reports().map { URL(fileURLWithPath: $0.path) }), //TODOLANG
                NanogramReportSection(folder: "logs", title: "App logs and critical logs", sources: logs.map { [$0] } ?? []), //TODOLANG
            ]
            let staging = NanogramLogExportFiles.stagingRoot(under: NanogramLogExportFiles.defaultRoot())
            let energy = NanogramExperimentEnergy.reportText()
            guard let staged = try? NanogramReport.stage(device: NanogramReportDevice.current(), sections: sections, settings: settingsLines, extraFiles: [(NanogramReport.energyFileName, energy)], in: staging) else {
                return []
            }
            return [staged]
        }
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
        let logs = ApiEnvironment.containerURL?.appendingPathComponent("logs", isDirectory: true)
        let ledger = logs.map { NanogramLogExportSpec.current(.metricKit).ledgerSources(logsDirectory: $0) } ?? []
        return {
            return MetricReportStore.shared.reports().map { URL(fileURLWithPath: $0.path) } + ledger
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
            completion(.failed)
            return
        }
        let send = NanogramLogChatSend(completion: completion)
        let share = NanogramLogShareObject(context, files: files, queued: { ids in
            send.track(ids, context: context)
        })
        context.window.makeKeyAndOrderFront(nil)
        showModal(with: ShareModalController(share, completion: { sent in
            send.pickerClosed(sent: sent)
        }), for: context.window)
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
    }, availableKinds: {
        return NanogramLogExportKind.allCases.filter(nanogramLogExportKindIsAvailable)
    }))
}
