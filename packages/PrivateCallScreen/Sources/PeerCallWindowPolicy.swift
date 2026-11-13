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

public func peerCallShowsIncomingCard(_ state: ExternalPeerCallState) -> Bool {
    if state.canBeRemoved {
        return false
    }
    if case .ringing = state.state {
        return true
    }
    return false
}

enum IncomingCallPanelConfiguration {
    static let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    static let collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    static let level: NSWindow.Level = .statusBar
    static let size = NSMakeSize(360, 96)
    static let margin: CGFloat = 16

    static func origin(in visibleFrame: NSRect) -> NSPoint {
        return NSMakePoint(visibleFrame.maxX - size.width - margin, visibleFrame.maxY - size.height - margin)
    }
}
