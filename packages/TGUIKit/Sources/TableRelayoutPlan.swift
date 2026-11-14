import Foundation

struct TableRelayoutPlan: Equatable {
    let immediate: Range<Int>
    let deferredChunks: [[Int]]

    init(count: Int, visible: NSRange, chunkSize: Int) {
        guard count > 0 else {
            self.immediate = 0 ..< 0
            self.deferredChunks = []
            return
        }
        let lower = min(max(visible.location, 0), count)
        let upper = min(max(visible.location + visible.length, lower), count)
        self.immediate = lower ..< upper

        var ordered: [Int] = []
        var below = lower - 1
        var above = upper
        while below >= 0 || above < count {
            if above < count {
                ordered.append(above)
                above += 1
            }
            if below >= 0 {
                ordered.append(below)
                below -= 1
            }
        }
        let size = max(chunkSize, 1)
        self.deferredChunks = stride(from: 0, to: ordered.count, by: size).map { Array(ordered[$0 ..< min($0 + size, ordered.count)]) }
    }
}
