import AppKit
import QuartzCore

public struct DisplayLinkRatePlan: Equatable {
    public let minimum: Int
    public let maximum: Int
    public let preferred: Int

    public static func make(requested: [SharedDisplayLinkDriver.FramesPerSecond], screenMaximum: Int, limit: Int? = nil) -> DisplayLinkRatePlan {
        var ceiling = max(1, screenMaximum)
        if let limit = limit {
            ceiling = min(ceiling, max(1, limit))
        }
        var preferred = 0
        for rate in requested {
            switch rate {
            case .max:
                preferred = max(preferred, ceiling)
            case let .fps(value):
                preferred = max(preferred, min(max(1, value), ceiling))
            }
        }
        if preferred == 0 {
            preferred = min(60, ceiling)
        }
        return DisplayLinkRatePlan(minimum: preferred, maximum: preferred, preferred: preferred)
    }

    @available(macOS 12.0, *)
    var frameRateRange: CAFrameRateRange {
        return CAFrameRateRange(minimum: Float(self.minimum), maximum: Float(self.maximum), preferred: Float(self.preferred))
    }
}

struct DisplayLinkFrameAccumulator {
    private(set) var accumulated: Double = 0

    mutating func advance(by elapsed: Double, secondsPerFrame: Double) -> Bool {
        self.accumulated += elapsed
        if self.accumulated >= secondsPerFrame * 0.95 {
            let remainder = self.accumulated - secondsPerFrame
            self.accumulated = remainder > 0 && remainder < secondsPerFrame ? remainder : 0
            return true
        }
        return false
    }
}

struct DisplayLinkDropCounter {
    private(set) var frames: Int = 0
    private(set) var droppedFrames: Int = 0
    private var lastTimestamp: Double?

    mutating func reset() {
        self.lastTimestamp = nil
    }

    mutating func record(timestamp: Double, interval: Double) -> Double? {
        defer {
            self.lastTimestamp = timestamp
        }
        self.frames += 1
        guard let last = self.lastTimestamp, timestamp > last else {
            return nil
        }
        let gap = timestamp - last
        if interval > 0, gap > interval * 1.5 {
            self.droppedFrames += max(0, Int((gap / interval).rounded()) - 1)
        }
        return gap
    }
}

protocol SharedDisplayLinkSource: AnyObject {
    var onFrame: ((_ timestamp: Double, _ targetTimestamp: Double) -> Void)? { get set }
    var maximumFramesPerSecond: Int { get }
    var isPaused: Bool { get set }
    func setScreen(_ screen: NSScreen?)
    func apply(_ plan: DisplayLinkRatePlan)
}

func makeDefaultSharedDisplayLinkSource() -> SharedDisplayLinkSource? {
    if #available(macOS 14.0, *) {
        return ScreenDisplayLinkSource()
    }
    return nil
}

@available(macOS 14.0, *)
final class ScreenDisplayLinkSource: SharedDisplayLinkSource {
    private final class Target: NSObject {
        weak var owner: ScreenDisplayLinkSource?

        @objc func tick(_ link: CADisplayLink) {
            self.owner?.onFrame?(link.timestamp, link.targetTimestamp)
        }
    }

    var onFrame: ((Double, Double) -> Void)?
    private let target = Target()
    private var link: CADisplayLink?
    private var screen: NSScreen?
    private var displayID: CGDirectDisplayID?
    private var plan: DisplayLinkRatePlan?

    var isPaused: Bool = true {
        didSet {
            self.link?.isPaused = self.isPaused
        }
    }

    init() {
        self.target.owner = self
    }

    deinit {
        self.link?.invalidate()
    }

    var maximumFramesPerSecond: Int {
        let value = (self.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60
        return value > 0 ? value : 60
    }

    func setScreen(_ screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else {
            return
        }
        let displayID = screen.displayLinkDisplayID
        if self.link != nil && displayID == self.displayID {
            self.screen = screen
            return
        }
        self.link?.invalidate()
        self.screen = screen
        self.displayID = displayID
        let link = screen.displayLink(target: self.target, selector: #selector(Target.tick(_:)))
        if let plan = self.plan {
            link.preferredFrameRateRange = plan.frameRateRange
        }
        link.isPaused = self.isPaused
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func apply(_ plan: DisplayLinkRatePlan) {
        if self.link == nil {
            self.setScreen(nil)
        }
        if self.plan != plan {
            self.plan = plan
            self.link?.preferredFrameRateRange = plan.frameRateRange
        }
    }
}

extension NSScreen {
    var displayLinkDisplayID: CGDirectDisplayID {
        if let number = self.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return CGMainDisplayID()
    }
}
