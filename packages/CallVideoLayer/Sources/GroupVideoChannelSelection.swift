import Foundation

public struct GroupVideoChannelCandidate: Equatable {
    public var endpointId: String
    public var isDominant: Bool
    public var isScreencast: Bool
    public var isLocal: Bool
    /// The tile is on screen (or within a row of it). Visible channels are never dropped by the cap.
    public var isVisible: Bool

    public init(endpointId: String, isDominant: Bool, isScreencast: Bool, isLocal: Bool, isVisible: Bool = false) {
        self.isVisible = isVisible
        self.endpointId = endpointId
        self.isDominant = isDominant
        self.isScreencast = isScreencast
        self.isLocal = isLocal
    }
}

public enum GroupVideoChannelSelection {
    public static let defaultRemoteLimit = 10

    public static func select(_ candidates: [GroupVideoChannelCandidate], remoteLimit: Int = GroupVideoChannelSelection.defaultRemoteLimit) -> Set<String> {
        var selected = Set<String>()
        var remote: [(offset: Int, element: GroupVideoChannelCandidate)] = []
        for (offset, candidate) in candidates.enumerated() {
            if candidate.isLocal {
                selected.insert(candidate.endpointId)
            } else {
                remote.append((offset, candidate))
            }
        }
        let ordered = remote.sorted(by: { lhs, rhs in
            if lhs.element.isDominant != rhs.element.isDominant {
                return lhs.element.isDominant
            }
            if lhs.element.isScreencast != rhs.element.isScreencast {
                return lhs.element.isScreencast
            }
            if lhs.element.isVisible != rhs.element.isVisible {
                return lhs.element.isVisible
            }
            return lhs.offset < rhs.offset
        })
        let visibleCount = remote.filter { $0.element.isVisible }.count
        for entry in ordered.prefix(max(0, remoteLimit, visibleCount)) {
            selected.insert(entry.element.endpointId)
        }
        return selected
    }
}
