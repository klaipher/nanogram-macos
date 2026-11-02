import Cocoa
import SwiftSignalKit
import AppKit

final class DisplayLinkGate {
    private var lock = os_unfair_lock()
    private var framesUntilDue: Int = 1
    private var pendingFrames: Int = 0
    
    func setFramesUntilDue(_ value: Int) {
        os_unfair_lock_lock(&self.lock)
        self.framesUntilDue = max(1, value)
        os_unfair_lock_unlock(&self.lock)
    }
    
    func tick() -> Int {
        os_unfair_lock_lock(&self.lock)
        self.pendingFrames += 1
        let result: Int
        if self.pendingFrames >= self.framesUntilDue {
            result = self.pendingFrames
            self.pendingFrames = 0
        } else {
            result = 0
        }
        os_unfair_lock_unlock(&self.lock)
        return result
    }
}

class DisplayLink
{
   let timer  : CVDisplayLink
   let source : DispatchSourceUserDataAdd
   let gate = DisplayLinkGate()
   
   var callback : Optional<(Int) -> ()> = nil
   
   var running : Bool { return CVDisplayLinkIsRunning(timer) }
   
   init?(onQueue queue: DispatchQueue = DispatchQueue.main)
   {
       source = DispatchSource.makeUserDataAddSource(queue: queue)
       
       var timerRef : CVDisplayLink? = nil
       
       guard CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &timerRef) == kCVReturnSuccess, let timer = timerRef else {
           NSLog("Failed to create timer with active display")
           return nil
       }
       guard CVDisplayLinkSetCurrentCGDisplay(timer, CGMainDisplayID()) == kCVReturnSuccess else {
           return nil
       }
       self.timer = timer
       
       let successLink = CVDisplayLinkSetOutputCallback(timer, { (timer: CVDisplayLink, currentTime: UnsafePointer<CVTimeStamp>, outputTime: UnsafePointer<CVTimeStamp>, _ : CVOptionFlags, _ : UnsafeMutablePointer<CVOptionFlags>, context : UnsafeMutableRawPointer?) -> CVReturn in
           if let context = context {
               let link = Unmanaged<DisplayLink>.fromOpaque(context).takeUnretainedValue()
               let frames = link.gate.tick()
               if frames > 0 {
                   link.source.add(data: UInt(frames))
               }
           }
           return kCVReturnSuccess
       }, Unmanaged.passUnretained(self).toOpaque())
       
       guard successLink == kCVReturnSuccess else {
           NSLog("Failed to create timer with active display")
           return nil
       }
       
       source.setEventHandler(handler: { [weak self] in
           guard let self else {
               return
           }
           self.callback?(max(1, Int(self.source.data)))
       })
   }
    
    var timestamp: TimeInterval {
        return CVDisplayLinkGetActualOutputVideoRefreshPeriod(self.timer)
    }

    func setDisplay(_ display: CGDirectDisplayID) {
        if CVDisplayLinkGetCurrentCGDisplay(self.timer) != display {
            CVDisplayLinkSetCurrentCGDisplay(self.timer, display)
        }
    }
   
   func start() {
       guard !running else { return }
       
       CVDisplayLinkStart(timer)
       source.resume()
   }
   
   func cancel()
   {
       guard running else { return }
       
       CVDisplayLinkStop(timer)
       source.cancel()
   }
   
   deinit
   {
       if running
       {
           cancel()
       }
   }
}



public protocol SharedDisplayLinkDriverLink: AnyObject {
    var isPaused: Bool { get set }
    
    func invalidate()
}

public final class SharedDisplayLinkDriver {
    public enum FramesPerSecond: Comparable {
        case fps(Int)
        case max
        
        public static func <(lhs: FramesPerSecond, rhs: FramesPerSecond) -> Bool {
            switch lhs {
            case let .fps(lhsFps):
                switch rhs {
                case let .fps(rhsFps):
                    return lhsFps < rhsFps
                case .max:
                    return true
                }
            case .max:
                return false
            }
        }
    }
    
    public typealias Link = SharedDisplayLinkDriverLink
    
    public static let shared = SharedDisplayLinkDriver()
    
    public final class LinkImpl: Link {
        private let driver: SharedDisplayLinkDriver
        public let framesPerSecond: FramesPerSecond
        let update: (CGFloat) -> Void
        var isValid: Bool = true
        public var isPaused: Bool = false {
            didSet {
                if self.isPaused != oldValue {
                    self.driver.requestUpdate()
                }
            }
        }
        
        init(driver: SharedDisplayLinkDriver, framesPerSecond: FramesPerSecond, update: @escaping (CGFloat) -> Void) {
            self.driver = driver
            self.framesPerSecond = framesPerSecond
            self.update = update
        }
        
        public func invalidate() {
            if self.isValid {
                self.isValid = false
                self.driver.requestUpdate()
            }
        }
    }
    
    private final class RequestContext {
        weak var link: LinkImpl?
        let framesPerSecond: FramesPerSecond
        
        var accumulator = DisplayLinkFrameAccumulator()
        
        init(link: LinkImpl, framesPerSecond: FramesPerSecond) {
            self.link = link
            self.framesPerSecond = framesPerSecond
        }
    }
    
    private let makeSource: () -> SharedDisplayLinkSource?
    private var source: SharedDisplayLinkSource?
    private var requests: [RequestContext] = []
    private(set) var deliveredEvents: Int = 0
    private var dropCounter = DisplayLinkDropCounter()
    private(set) var plan: DisplayLinkRatePlan?
    
    private var isInForeground: Bool = false
    private var isProcessingEvent: Bool = false
    private var isUpdateRequested: Bool = false
    private var observers: [NSObjectProtocol] = []
    
    public var maximumFramesPerSecondLimit: Int? {
        didSet {
            if self.maximumFramesPerSecondLimit != oldValue {
                self.requestUpdate()
            }
        }
    }
    
    public var droppedFrames: Int {
        return self.dropCounter.droppedFrames
    }
    
    public var presentedFrames: Int {
        return self.dropCounter.frames
    }
    
    private convenience init() {
        self.init(makeSource: makeDefaultSharedDisplayLinkSource)

        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification] {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] _ in
                self?.updateDisplay()
            }))
        }
    }
    
    init(makeSource: @escaping () -> SharedDisplayLinkSource?) {
        self.makeSource = makeSource
        self.isInForeground = true
        self.update()
    }
    
    private var targetScreen: NSScreen? {
        return NSApp?.keyWindow?.screen ?? NSApp?.mainWindow?.screen ?? NSScreen.main
    }
    
    func updateDisplay() {
        guard let source = self.source else {
            return
        }
        source.setScreen(self.targetScreen)
        self.requestUpdate()
    }
    
    public func updateForegroundState(_ isActive: Bool) {
        if self.isInForeground != isActive {
            self.isInForeground = isActive
            self.requestUpdate()
        }
    }
    
    private func requestUpdate() {
        if self.isProcessingEvent {
            self.isUpdateRequested = true
        } else {
            self.update()
        }
    }
    
    private func update() {
        self.requests.removeAll(where: { request in
            guard let link = request.link else {
                return true
            }
            return !link.isValid
        })
        var requested: [FramesPerSecond] = []
        for request in self.requests {
            if let link = request.link, link.isValid && !link.isPaused {
                requested.append(link.framesPerSecond)
            }
        }
        
        if self.isInForeground && !requested.isEmpty {
            if self.source == nil {
                let source = self.makeSource()
                source?.onFrame = { [weak self] timestamp, targetTimestamp in
                    self?.displayLinkEvent(timestamp: timestamp, targetTimestamp: targetTimestamp)
                }
                source?.setScreen(self.targetScreen)
                self.source = source
            }
            guard let source = self.source else {
                return
            }
            let plan = DisplayLinkRatePlan.make(requested: requested, screenMaximum: source.maximumFramesPerSecond, limit: self.maximumFramesPerSecondLimit)
            self.plan = plan
            source.apply(plan)
            if source.isPaused {
                self.dropCounter.reset()
                source.isPaused = false
            }
        } else if let source = self.source, !source.isPaused {
            source.isPaused = true
        }
    }
    
    private func displayLinkEvent(timestamp: Double, targetTimestamp: Double) {
        self.isProcessingEvent = true
        self.deliveredEvents += 1
        let screenMaximum = Double(self.plan?.maximum ?? 60)
        let frameDuration = targetTimestamp > timestamp ? targetTimestamp - timestamp : 1.0 / screenMaximum
        let expectedInterval = max(frameDuration, 1.0 / Double(self.plan?.preferred ?? 60))
        let gap = self.dropCounter.record(timestamp: timestamp, interval: expectedInterval)
        let elapsed = min(gap ?? frameDuration, 0.25)
        
        var removeIndices: [Int]?
        loop: for i in 0 ..< self.requests.count {
            let request = self.requests[i]
            if let link = request.link, link.isValid {
                if !link.isPaused {
                    var itemDuration = CGFloat(frameDuration)
                    
                    switch request.framesPerSecond {
                    case let .fps(value):
                        let secondsPerFrame = 1.0 / Double(value)
                        itemDuration = CGFloat(secondsPerFrame)
                        if !request.accumulator.advance(by: elapsed, secondsPerFrame: secondsPerFrame) {
                            continue loop
                        }
                    case .max:
                        break
                    }
                    
                    link.update(itemDuration)
                }
            } else {
                if removeIndices == nil {
                    removeIndices = [i]
                } else {
                    removeIndices?.append(i)
                }
            }
        }
        if let removeIndices = removeIndices {
            for index in removeIndices.reversed() {
                self.requests.remove(at: index)
            }
            
            self.isUpdateRequested = true
        }
        
        self.isProcessingEvent = false
        if self.isUpdateRequested {
            self.isUpdateRequested = false
            self.update()
        }
    }
    
    public func add(framesPerSecond: FramesPerSecond = .fps(60), _ update: @escaping (CGFloat) -> Void) -> Link {
        let link = LinkImpl(driver: self, framesPerSecond: framesPerSecond, update: update)
        self.requests.append(RequestContext(link: link, framesPerSecond: framesPerSecond))
        
        self.requestUpdate()
        
        return link
    }
}




private final class DisplayLinkTarget: NSObject {
    private let f: () -> Void
    
    init(_ f: @escaping () -> Void) {
        self.f = f
    }
    
    @objc func event() {
        self.f()
    }
}


private struct UnitBezier {
    private let ax: Float;
    private let bx: Float;
    private let cx: Float;
    
    private let ay: Float;
    private let by: Float;
    private let cy: Float;
    
    init(_ p1x: Float, _ p1y: Float, _ p2x: Float, _ p2y: Float) {
        self.cx = 3.0 * p1x;
        self.bx = 3.0 * (p2x - p1x) - cx;
        self.ax = 1.0 - cx - bx;
        
        self.cy = 3.0 * p1y;
        self.by = 3.0 * (p2y - p1y) - cy;
        self.ay = 1.0 - cy - by;
    }

    func sampleCurveX(_ t: Float) -> Float {
        return ((ax * t + bx) * t + cx) * t;
    }

    func sampleCurveY(_ t: Float) -> Float {
        return ((ay * t + by) * t + cy) * t;
    }
  
    func sampleCurveDerivativeX(_ t: Float) -> Float {
        return (3.0 * ax * t + 2.0 * bx) * t + cx;
    }
  
    func solveCurveX(_ x: Float, _ epsilon: Float) -> Float{
        var t0:Float = 0;
        var t1:Float = 0;
        var t2:Float = 0;
        var x2:Float = 0;
        var d2:Float = 0;
    
        for _ in 0 ..< 8 {
            t2 = x;
            x2 = sampleCurveX(t2) - x;
            if (abs (x2) < epsilon) {
                return t2;
            }
            d2 = sampleCurveDerivativeX(t2);
            if (abs(d2) < 1e-6) {
                break;
            }
            t2 = t2 - x2 / d2;
        }
        t0 = 0.0;
        t1 = 1.0;
        t2 = x;
    
        if (t2 < t0) {
            return t0;

        }
        if (t2 > t1) {
            return t1;
        }
    
        while (t0 < t1) {
            x2 = sampleCurveX(t2);
            if (abs(x2 - x) < epsilon) {
                return t2;
            }
            if (x > x2) {
                t0 = t2;
            } else {
                t1 = t2;
            }
            t2 = (t1 - t0) * 0.5 + t0;
        }
        return t2;
    }
  
    func solve(_ x: Float, _ epsilon: Float) -> Float {
        return sampleCurveY(solveCurveX(x, epsilon));
    }
}

private func TimingFunctionSolve(_ vec: [Float], _ t: Float, _ eps: Float) -> Float {
    let bezier = UnitBezier(vec[0], vec[1], vec[2], vec[3]);
    return bezier.solve(t, eps);
}
private func solveEps(_ duration: Float) -> Float {
    return (1.0 / (1000.0 * (duration)))
}

public final class DisplayLinkAnimator {
    private var displayLink: SharedDisplayLinkDriver.Link?
    private let duration: Double
    private let fromValue: CGFloat
    private let toValue: CGFloat
    private let startTime: Double
    private let update: (CGFloat) -> Void
    private let completion: () -> Void
    private var completed = false
    private var timingControlPoints:[Float] = [0, 0, 0, 0];

    public init(duration: Double, from fromValue: CGFloat, to toValue: CGFloat, timingFunction: CAMediaTimingFunction = .init(name: .easeOut), update: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        self.duration = duration
        self.fromValue = fromValue
        self.toValue = toValue
        self.update = update
        self.completion = completion
        
        var firstTwo:[Float] = [0, 0]
        var lastTwo:[Float] = [0, 0]

        timingFunction.getControlPoint(at: 1, values: &firstTwo)
        timingFunction.getControlPoint(at: 2, values: &lastTwo)

        for i in 0 ..< firstTwo.count {
            timingControlPoints[i] = firstTwo[i]
        }
        for i in 0 ..< lastTwo.count {
            timingControlPoints[i + firstTwo.count] = lastTwo[i]
        }
        self.startTime = CACurrentMediaTime()
        
        self.displayLink = SharedDisplayLinkDriver.shared.add(framesPerSecond: .max, { [weak self] _ in
            self?.tick(false)
        })
        

        self.tick(true)
    }
    
    deinit {
        self.displayLink?.invalidate()
        self.displayLink = nil
    }
    
    public func invalidate() {
        self.displayLink?.invalidate()
        self.displayLink = nil
    }
    
    @objc private func tick(_ isFirst: Bool) {
        if self.completed {
            return
        }
        let timestamp = CACurrentMediaTime()
        var t = min(timestamp - self.startTime, self.duration) / self.duration
        t = max(0.0, t)
        t = min(1.0, t)
        
        let solved: Float
        if isFirst {
            solved = 0
        } else {
            solved = TimingFunctionSolve(timingControlPoints, Float(t), solveEps(Float(duration)));
        }
        
        self.update(self.fromValue * CGFloat(1 - solved) + self.toValue * CGFloat(solved))
        if abs(t - 1.0) < Double.ulpOfOne {
            self.completed = true
            self.displayLink?.invalidate()
            self.completion()
        }
    }
}

public enum FrameStep {
    public static func scale(_ duration: CGFloat) -> CGFloat {
        return duration * 60
    }

    public static func decay(_ factor: CGFloat, _ duration: CGFloat) -> CGFloat {
        return pow(factor, duration * 60)
    }

    public static func blend(_ factor: CGFloat, _ duration: CGFloat) -> CGFloat {
        return 1 - pow(1 - factor, duration * 60)
    }
}

public final class ConstantDisplayLinkAnimator {
    private var displayLink: SharedDisplayLinkDriver.Link?
    private let update: (CGFloat) -> Void
    private var completed = false
    private let framesPerSecond: SharedDisplayLinkDriver.FramesPerSecond

    
    public var isPaused: Bool = true {
        didSet {
            if self.isPaused != oldValue {
                if self.isPaused {
                    self.displayLink = nil
                } else {
                    self.displayLink = SharedDisplayLinkDriver.shared.add(framesPerSecond: self.framesPerSecond, { [weak self] duration in
                        self?.tick(duration)
                    })
                }
            }
        }
    }
    
    public init(update: @escaping () -> Void, fps: TimeInterval = 60) {
        self.update = { _ in update() }
        self.framesPerSecond = .fps(Int(fps))
    }
    
    public init(framesPerSecond: SharedDisplayLinkDriver.FramesPerSecond, update: @escaping (CGFloat) -> Void) {
        self.update = update
        self.framesPerSecond = framesPerSecond
    }
    
    deinit {
        self.displayLink?.invalidate()
    }
    
    public func invalidate() {
        self.displayLink?.invalidate()
    }
    
    private func tick(_ duration: CGFloat) {
        if self.completed {
            return
        }
        self.update(duration)
    }
}

