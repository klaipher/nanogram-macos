import SwiftSignalKit

public let resourcesQueue = Queue(name: "ResourcesQueue", qos: .utility)
public let prepareQueue = Queue(name: "PrepareQueue", qos: .utility)
/// Chat list, forum topics and saved-messages lists: first display must not wait behind search, panels or background work.
public let chatListPrepareQueue = Queue(name: "ChatListPrepareQueue", qos: .userInitiated)
public let messagesViewQueue = Queue(name: "messagesViewQueue", qos: .utility)

public func deliverOnPrepareQueue<T, E>(_ signal: Signal<T, E>) -> Signal<T, E> {
    return signal |> deliverOn(prepareQueue)
}

public func deliverOnChatListPrepareQueue<T, E>(_ signal: Signal<T, E>) -> Signal<T, E> {
    return signal |> deliverOn(chatListPrepareQueue)
}

public func deliverOnResourceQueue<T, E>(_ signal: Signal<T, E>) -> Signal<T, E> {
    return signal |> deliverOn(resourcesQueue)
}
