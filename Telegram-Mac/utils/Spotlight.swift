import Cocoa
import CoreSpotlight

import TelegramCore
import Postbox
import SwiftSignalKit
import TGUIKit
import MurMurHash32
import TelegramTheme
import TelegramLinks
import TelegramUtils
import NanogramRuntime

public enum SpotlightIdentifierSource : Equatable {
    case peerId(PeerId)
    
    fileprivate var stringValue: String {
        switch self {
        case let .peerId(peerId):
            return "peerId:\(peerId.toInt64())"
        }
    }
}

public struct SpotlightIdentifier : Hashable {
    public let recordId: AccountRecordId
    public let source:SpotlightIdentifierSource
    
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(stringValue)
    }
    
    fileprivate var stringValue: String {
        return "accountId=\(recordId.int64)&source=\(source.stringValue)"
    }
}
public final class SpotlightContext {
    public let engine: TelegramEngine
    private let disposable = MetaDisposable()
    private let peerIndex: SpotlightPeerIndex

    public init(engine: TelegramEngine, isLocked: Bool) {
        self.engine = engine
        let account = engine.account
        let accountId = account.id
        self.peerIndex = SpotlightPeerIndex(accountId: accountId.int64)
        self.peerIndex.setLocked(isLocked)

        let accountPeer = account.postbox.loadedPeerWithId(account.peerId)
        let recently = engine.peers.recentlySearchedPeers() |> map {
            $0.compactMap { $0.peer.chatMainPeer }
        }
        let recent: Signal<[Peer], NoError> = engine.peers.recentPeers() |> map { recent in
            switch recent {
            case .disabled:
                return []
            case let .peers(peers):
                return peers
            }
        }
        let peers: Signal<[Peer], NoError> = combineLatest(recently, recent) |> map { recently, recent in
            var seen = Set<PeerId>()
            return (recently + recent).filter { seen.insert($0.id).inserted }
        } |> distinctUntilChanged(isEqual: { previous, current in
            return previous.count == current.count && zip(previous, current).allSatisfy { $0.id == $1.id && $0.displayTitle == $1.displayTitle }
        })

        let entries: Signal<[SpotlightPeerEntry], NoError> = combineLatest(accountPeer, peers) |> mapToSignal { accountPeer, peers in
            let accountTitle = accountPeer.addressName ?? accountPeer.displayTitle
            let avatars: [Signal<Data?, NoError>] = peers.map { peer in
                return peerAvatarImage(account: account, photo: .peer(peer, peer.smallProfileImage, peer.namePeerColor, peer.displayLetters, nil, nil), displayDimensions: NSMakeSize(64, 64), genCap: false)
                    |> take(1)
                    |> map { image, _ in
                        return image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
                    }
            }
            return combineLatest(avatars) |> map { avatars in
                return zip(peers, avatars).map { peer, avatar in
                    let key = SpotlightIdentifier(recordId: accountId, source: .peerId(peer.id))
                    return SpotlightPeerEntry(peerId: peer.id.toInt64(), uniqueIdentifier: key.stringValue, title: peer.displayTitle, accountTitle: accountTitle, avatarPNG: avatar)
                }
            }
        } |> deliverOnMainQueue

        disposable.set(entries.start(next: { [weak self] entries in
            self?.peerIndex.update(entries)
        }))
    }

    public func setLocked(_ isLocked: Bool) {
        peerIndex.setLocked(isLocked)
    }

    public func removeFromIndex() {
        disposable.dispose()
        peerIndex.removeAll()
    }

    deinit {
        disposable.dispose()
    }
}

public func parseSpotlightIdentifier(_ unique: String) -> SpotlightIdentifier? {
    let (vars, _) = urlVars(with: unique)
    
    if let source = vars["source"], let rawAccountId = vars["accountId"], let int64AccountId = Int64(rawAccountId)  {
        let accountId = AccountRecordId(rawValue: int64AccountId)
        let sourceComponents = source.components(separatedBy: ":")
        if sourceComponents.count == 2 {
            switch sourceComponents[0] {
            case "peerId":
                if let id = Int64(sourceComponents[1]) {
                    let peerId = PeerId(id)
                    return SpotlightIdentifier(recordId: accountId, source: .peerId(peerId))
                }
            default:
                break
            }
        }
    }

    
    return nil
}

