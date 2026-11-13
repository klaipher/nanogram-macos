import Foundation

public enum IncomingCallActiveCall<ID: Hashable>: Equatable {
    case p2p(id: ID, isEnded: Bool)
    case group
}

public enum IncomingCallRingAction: Equatable {
    case present
    case replaceEndedSession
    case rejectBusy
    case ignore
}

public enum IncomingCallPolicy {
    public static let ringGateGrace: TimeInterval = 1.5
    public static let sessionDataTimeout: TimeInterval = 2.0

    public static func ringAction<ID: Hashable>(ringId: ID, active: IncomingCallActiveCall<ID>?) -> IncomingCallRingAction {
        guard let active = active else {
            return .present
        }
        switch active {
        case .group:
            return .rejectBusy
        case let .p2p(id, isEnded):
            if id == ringId {
                return .ignore
            }
            return isEnded ? .replaceEndedSession : .rejectBusy
        }
    }

    public static func isRingReady(isUpdating: Bool, graceElapsed: Bool) -> Bool {
        return !isUpdating || graceElapsed
    }

    public static func shouldAnimateWindow(isIncoming: Bool, reduceMotion: Bool) -> Bool {
        return !isIncoming && !reduceMotion
    }

    public static func hidesCaller(isLocked: Bool, previewsEnabled: Bool) -> Bool {
        return isLocked || !previewsEnabled
    }

    public static func displayTitle(callerName: String?, hidesCaller: Bool, appName: String) -> String {
        guard !hidesCaller, let callerName = callerName, !callerName.isEmpty else {
            return appName
        }
        return callerName
    }
}

public struct IncomingCallRingLedger<ID: Hashable> {
    private var handled: Set<ID> = []

    public init() {
    }

    public mutating func prune(keeping live: Set<ID>) {
        self.handled.formIntersection(live)
    }

    public mutating func decide(ringId: ID, active: IncomingCallActiveCall<ID>?) -> IncomingCallRingAction {
        if self.handled.contains(ringId) {
            return .ignore
        }
        let action = IncomingCallPolicy.ringAction(ringId: ringId, active: active)
        if action != .ignore {
            self.handled.insert(ringId)
        }
        return action
    }
}
