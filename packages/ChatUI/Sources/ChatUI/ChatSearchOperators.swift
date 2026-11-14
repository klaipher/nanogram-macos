import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit
import NanogramRuntime

extension SearchOperatorType {
    var messageTags: MessageTags {
        switch self {
        case .photo:
            return .photo
        case .video:
            return .video
        case .file:
            return .file
        case .link:
            return .webPage
        case .voice:
            return .voice
        case .music:
            return .music
        case .gif:
            return .gif
        case .round:
            return .roundVideo
        case .poll:
            return .polls
        case .pinned:
            return .pinned
        }
    }
}

struct ChatSearchSender {
    let isResolved: Bool
    let peerId: PeerId?
}

func chatSearchSender(_ sender: SearchOperatorSender?, fallback: PeerId?, engine: TelegramEngine) -> Signal<ChatSearchSender, NoError> {
    switch sender {
    case .none:
        return .single(ChatSearchSender(isResolved: true, peerId: fallback))
    case let .some(.userId(id)):
        return .single(ChatSearchSender(isResolved: true, peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(id))))
    case let .some(.username(name)):
        return engine.peers.resolvePeerByName(name: name, referrer: nil)
        |> mapToSignal { result -> Signal<ChatSearchSender, NoError> in
            switch result {
            case .progress:
                return .complete()
            case let .result(peer):
                return .single(ChatSearchSender(isResolved: peer != nil, peerId: peer?.id))
            }
        }
        |> take(1)
    }
}
