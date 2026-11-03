public struct GalleryReleaseSchedule {
    public struct Decision: Equatable {
        public let indices: [Int]
        public let oldRuleWouldReleaseDisplayed: Bool
    }

    public private(set) var isDeferred: Bool = false

    public init() {}

    public mutating func note(itemCount: Int, index: Int, displayedIndex: Int?, pending: Bool) -> Decision {
        isDeferred = pending
        let indices = GalleryItemRelease.indicesToRelease(itemCount: itemCount, around: index, displayedIndex: displayedIndex, hasPendingChanges: pending)
        let oldRuleWouldReleaseDisplayed = pending && displayedIndex.map { abs($0 - index) > 1 } == true
        return Decision(indices: indices, oldRuleWouldReleaseDisplayed: oldRuleWouldReleaseDisplayed)
    }

    public mutating func flush(itemCount: Int, displayedIndex: Int, pending: Bool) -> [Int] {
        guard isDeferred, !pending, itemCount > 0 else {
            return []
        }
        return note(itemCount: itemCount, index: displayedIndex, displayedIndex: displayedIndex, pending: false).indices
    }
}
