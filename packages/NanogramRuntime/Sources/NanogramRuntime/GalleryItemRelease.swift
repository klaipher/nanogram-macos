public enum GalleryItemRelease {
    public static func indicesToRelease(itemCount: Int, around index: Int, displayedIndex: Int?, hasPendingChanges: Bool) -> [Int] {
        guard !hasPendingChanges else {
            return []
        }
        return (0 ..< max(itemCount, 0)).filter { abs($0 - index) > 1 && $0 != displayedIndex }
    }
}
