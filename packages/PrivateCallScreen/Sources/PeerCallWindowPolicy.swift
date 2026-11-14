import AppKit

public enum PeerCallCloseAction: Equatable {
    case declineCall
    case removeSession
    case closeWindow
}

public func peerCallCloseAction(for state: ExternalPeerCallState.State) -> PeerCallCloseAction {
    switch state {
    case .ringing:
        return .declineCall
    case let .terminated(reason):
        if let reason = reason, reason.recall {
            return .removeSession
        }
        return .closeWindow
    default:
        return .closeWindow
    }
}

public enum PeerCallEndStep: Equatable {
    case hangUp
    case markRemovable
}

// Hang-up goes first: marking the session removable tears the window down synchronously and can free the
// session, whose deinit would then discard the call as a disconnect ("Call failed" for the other side).
public func peerCallEndSteps(for state: ExternalPeerCallState.State) -> [PeerCallEndStep] {
    switch state {
    case let .terminated(reason):
        if let reason = reason, reason.recall {
            return [.markRemovable]
        }
        return []
    default:
        return [.hangUp, .markRemovable]
    }
}

public func peerCallIsRinging(_ state: ExternalPeerCallState) -> Bool {
    if state.canBeRemoved {
        return false
    }
    if case .ringing = state.state {
        return true
    }
    return false
}

struct PeerCallWindowPresentation: Equatable {
    let collectionBehavior: NSWindow.CollectionBehavior
    let level: NSWindow.Level
}

// While an incoming call rings the call window itself must show on every Space and over full-screen apps.
func peerCallWindowPresentation(ringing: Bool, normalBehavior: NSWindow.CollectionBehavior, normalLevel: NSWindow.Level) -> PeerCallWindowPresentation {
    guard ringing else {
        return PeerCallWindowPresentation(collectionBehavior: normalBehavior, level: normalLevel)
    }
    return PeerCallWindowPresentation(collectionBehavior: normalBehavior.union([.canJoinAllSpaces, .fullScreenAuxiliary]), level: .statusBar)
}
