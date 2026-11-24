import Cocoa
import TGUIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import InputDataUI
import GeneralRows
import Localization
import TelegramContext
import TelegramTheme
import ColorPalette
import LocalAnimations
import TelegramUtils
import AlertsUI

// Nanogram: per-topic notification exceptions of a forum, like iOS NotificationExceptionsScreen (forum peer).
private struct TopicExceptionsState: Equatable {
    var exceptions: [EngineMessageHistoryThread.NotificationException] = []
    var loaded: Bool = false
}

private func topicExceptionStatus(_ settings: EnginePeer.NotificationSettings, now: Int32) -> String {
    var components: [String] = []
    switch settings.muteState {
    case .unmuted:
        components.append(strings().notificationSettingsExceptionsAlwaysOn)
    case let .muted(until):
        if until >= Int32.max - 1 {
            return strings().notificationSettingsExceptionsAlwaysOff
        } else if until > now {
            components.append(strings().notificationSettingsExceptionsMutedUntil(stringForMediumDate(timestamp: until)))
        } else {
            components.append(strings().notificationSettingsExceptionsAlwaysOn)
        }
    case .default:
        break
    }
    switch settings.messageSound {
    case .default:
        break
    default:
        components.append(strings().notificationSettingsExceptionsCustomSound)
    }
    switch settings.displayPreviews {
    case .show:
        components.append(strings().notificationSettingsExceptionsShowPreview)
    case .hide:
        components.append(strings().notificationSettingsExceptionsHidePreview)
    case .default:
        break
    }
    return components.joined(separator: ", ")
}

func NotificationTopicExceptionsController(context: any AccountContextProtocol, peer: EnginePeer) -> InputDataController {
    let peerId = peer.id
    let actionsDisposable = DisposableSet()

    let initialState = TopicExceptionsState()
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((TopicExceptionsState) -> TopicExceptionsState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    let remove:([Int64]) -> Void = { threadIds in
        guard !threadIds.isEmpty else {
            return
        }
        _ = context.engine.peers.removeCustomThreadNotificationSettings(peerId: peerId, threadIds: threadIds).start()
        updateState { current in
            var current = current
            current.exceptions.removeAll(where: { threadIds.contains($0.threadId) })
            return current
        }
    }

    actionsDisposable.add((context.engine.peers.forumChannelTopicNotificationExceptions(id: peerId) |> deliverOnMainQueue).start(next: { exceptions in
        updateState { current in
            var current = current
            current.exceptions = exceptions
            current.loaded = true
            return current
        }
    }))

    let signal = statePromise.get() |> filter { $0.loaded } |> deliverOnPrepareQueue |> map { state -> InputDataSignalValue in
        var entries: [InputDataEntry] = []
        var sectionId: Int32 = 0
        var index: Int32 = 0

        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1

        entries.append(.desc(sectionId: sectionId, index: index, text: .plain(strings().notificationSettingsExceptionsHeader), data: .init(color: theme.colors.listGrayText, viewType: .textTopItem)))
        index += 1

        let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
        let rows = state.exceptions
        for (i, exception) in rows.enumerated() {
            let threadId = exception.threadId
            entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("_id_topic_exception_\(threadId)"), data: .init(name: exception.info.title, color: theme.colors.text, type: .none, viewType: bestGeneralViewType(rows, for: i), description: topicExceptionStatus(exception.notificationSettings, now: now), menuItems: {
                return [ContextMenuItem(strings().notificationSettingsExceptionsRemove, handler: {
                    remove([threadId])
                }, itemMode: .destruct, itemImage: MenuAnimation.menu_delete.value)]
            })))
            index += 1
        }

        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1

        if !rows.isEmpty {
            entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("_id_topic_exceptions_delete_all"), data: .init(name: strings().notificationSettingsExceptionsDeleteAll, color: theme.colors.redUI, type: .none, viewType: .singleItem, action: {
                verifyAlert_button(for: context.window, information: strings().notificationSettingsExceptionsDeleteAllConfirm, ok: strings().notificationSettingsExceptionsDeleteAll, successHandler: { _ in
                    remove(stateValue.with { $0.exceptions.map(\.threadId) })
                })
            })))
            index += 1

            entries.append(.sectionId(sectionId, type: .normal))
            sectionId += 1
        }
        return InputDataSignalValue(entries: entries)
    }

    let controller = InputDataController(dataSignal: signal, title: peer._asPeer().displayTitle, removeAfterDisappear: true, hasDone: false, identifier: "notification-topic-exceptions")

    controller.onDeinit = {
        actionsDisposable.dispose()
    }

    return controller
}
