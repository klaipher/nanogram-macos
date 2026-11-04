import Cocoa

struct StoryRevealLayoutGate<State: Equatable> {
    private var last: (fraction: CGFloat, state: State)?

    mutating func shouldLayout(fraction: CGFloat, state: State, force: Bool = false) -> Bool {
        if !force, let last = self.last, last.fraction == fraction, last.state == state {
            return false
        }
        self.last = (fraction, state)
        return true
    }
}
