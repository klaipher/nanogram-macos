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
    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let subtitleFont = NSFont.systemFont(ofSize: 12)
    static let buttonFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    private static let padding: CGFloat = 14
    private static let iconSide: CGFloat = 56
    private static let textInset: CGFloat = 84
    private static let titleHeight: CGFloat = 20
    private static let subtitleHeight: CGFloat = 16
    private static let titleGap: CGFloat = 2
    private static let buttonGap: CGFloat = 10
    private static let buttonHeight: CGFloat = 28
    private static let buttonSpacing: CGFloat = 8

    static let size = NSMakeSize(360, padding + titleHeight + titleGap + subtitleHeight + buttonGap + buttonHeight + padding)
    static let margin: CGFloat = 16

    struct Layout {
        let icon: NSRect
        let title: NSRect
        let subtitle: NSRect
        let decline: NSRect
        let accept: NSRect
    }

    static var layout: Layout {
        let textWidth = size.width - textInset - padding
        let titleY = size.height - padding - titleHeight
        let subtitleY = titleY - titleGap - subtitleHeight
        let buttonWidth = (textWidth - buttonSpacing) / 2
        return Layout(
            icon: NSMakeRect(16, (size.height - iconSide) / 2, iconSide, iconSide),
            title: NSMakeRect(textInset, titleY, textWidth, titleHeight),
            subtitle: NSMakeRect(textInset, subtitleY, textWidth, subtitleHeight),
            decline: NSMakeRect(textInset, padding, buttonWidth, buttonHeight),
            accept: NSMakeRect(textInset + buttonWidth + buttonSpacing, padding, buttonWidth, buttonHeight)
        )
    }

    static func origin(in visibleFrame: NSRect) -> NSPoint {
        return NSMakePoint(visibleFrame.maxX - size.width - margin, visibleFrame.maxY - size.height - margin)
    }
}
