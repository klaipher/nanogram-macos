import AppKit

private final class EventMonitorRegistration {
    private let token: Any
    private let remove: (Any) -> Void

    init(token: Any, remove: @escaping (Any) -> Void) {
        self.token = token
        self.remove = remove
    }

    deinit {
        self.remove(self.token)
    }
}

@MainActor
public final class ClosingKeySwallow {
    public typealias EventHandler = (NSEvent) -> NSEvent?

    private let maxDuration: TimeInterval
    private let now: () -> TimeInterval
    private let installMonitor: (@escaping EventHandler) -> Any?
    private let removeMonitor: (Any) -> Void
    private var monitor: EventMonitorRegistration?
    private var deadline: TimeInterval?

    public init(
        maxDuration: TimeInterval = 1.0,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        installMonitor: @escaping (@escaping EventHandler) -> Any? = { NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: $0) },
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
    ) {
        self.maxDuration = maxDuration
        self.now = now
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
    }

    public var isActive: Bool {
        guard let deadline = self.deadline else {
            return false
        }
        return self.now() < deadline
    }

    public func begin() {
        self.deadline = self.now() + self.maxDuration
        if self.monitor == nil {
            let token = self.installMonitor { [weak self] event in
                guard let self = self else {
                    return event
                }
                let type = event.type
                let modifierFlags = event.modifierFlags
                let swallow = MainActor.assumeIsolated {
                    self.shouldSwallow(type: type, modifierFlags: modifierFlags)
                }
                return swallow ? nil : event
            }
            if let token = token {
                self.monitor = EventMonitorRegistration(token: token, remove: self.removeMonitor)
            }
        }
    }

    public func end() {
        self.deadline = nil
        self.monitor = nil
    }

    public func shouldSwallow(type: NSEvent.EventType, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard self.isActive, type == .keyDown else {
            return false
        }
        return !modifierFlags.contains(.command)
    }
}

@MainActor
private final class RunLoopTurnTrampoline: NSObject {
    private let work: @MainActor () -> Void

    init(work: @escaping @MainActor () -> Void) {
        self.work = work
    }

    @objc func fire() {
        self.work()
    }
}

@MainActor
public final class OverlayCloseSequence {
    public typealias Schedule = (@escaping @MainActor () -> Void) -> Void

    public static let nextRunLoopTurn: Schedule = { work in
        let trampoline = RunLoopTurnTrampoline(work: work)
        let timer = Timer(timeInterval: 0, target: trampoline, selector: #selector(RunLoopTurnTrampoline.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
    }

    private let keySwallow: ClosingKeySwallow
    private let schedule: Schedule
    private var generation = 0

    public init(keySwallow: ClosingKeySwallow? = nil, schedule: @escaping Schedule = OverlayCloseSequence.nextRunLoopTurn) {
        self.keySwallow = keySwallow ?? ClosingKeySwallow()
        self.schedule = schedule
    }

    public var isClosing: Bool {
        return self.keySwallow.isActive
    }

    public func close(startAnimation: () -> Void, handOffKey: @escaping @MainActor () -> Void) {
        self.generation += 1
        let generation = self.generation
        self.keySwallow.begin()
        startAnimation()
        self.schedule { [weak self] in
            guard let self = self, self.generation == generation else {
                return
            }
            handOffKey()
        }
    }

    public func finish() {
        self.generation += 1
        self.keySwallow.end()
    }
}
