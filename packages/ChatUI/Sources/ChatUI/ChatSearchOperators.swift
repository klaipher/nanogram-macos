import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit
import NanogramRuntime

extension SearchOperatorType {
    // nil for the operator types the Mac does not parse (`SearchOperators.macSupportedTypes`).
    var messageTags: MessageTags? {
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
        case .contact, .geo, .mention:
            return nil
        }
    }
}

struct ChatSearchSender {
    let restoresFromToken: Bool
    let peerId: PeerId?
}

// A name that does not resolve leaves the `from:` token in the text, so the search never gets wider than the words typed.
func chatSearchSender(_ parsed: ParsedSearchQuery, fallback: PeerId?, accountPeerId: PeerId, engine: TelegramEngine) -> Signal<ChatSearchSender, NoError> {
    guard parsed.fromName != nil else {
        return .single(ChatSearchSender(restoresFromToken: false, peerId: fallback))
    }
    if parsed.isMe {
        return .single(ChatSearchSender(restoresFromToken: false, peerId: accountPeerId))
    }
    guard let name = parsed.resolvableUsername else {
        return .single(ChatSearchSender(restoresFromToken: true, peerId: fallback))
    }
    return engine.peers.resolvePeerByName(name: name, referrer: nil)
    |> mapToSignal { result -> Signal<ChatSearchSender, NoError> in
        switch result {
        case .progress:
            return .complete()
        case let .result(peer):
            if let peer = peer {
                return .single(ChatSearchSender(restoresFromToken: false, peerId: peer.id))
            }
            return .single(ChatSearchSender(restoresFromToken: true, peerId: fallback))
        }
    }
    |> take(1)
}
