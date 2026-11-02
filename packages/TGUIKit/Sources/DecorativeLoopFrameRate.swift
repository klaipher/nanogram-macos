import QuartzCore

public extension CAAnimation {
    func setDecorativeLoopFrameRate() {
        if #available(macOS 12.0, *) {
            self.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
    }
}
